# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Stream.Take do
  @moduledoc """
  A long-lived connection to `/jobs/take`, delivering jobs to an owner
  process as they arrive.

  This is the low-level consumer. Most applications want `Zizq.Worker`,
  which runs one of these and handles concurrency, acknowledgement and
  shutdown. Use this directly only if you need to drive the loop
  yourself.

      {:ok, _pid} = Zizq.Stream.Take.start_link(client: MyApp.Zizq, prefetch: 10)

      receive do
        {:zizq_stream, _pid, {:job, job}} -> handle(job)
      end

  ## Messages

  The owner (by default whoever called `start_link/1`) receives:

    * `{:zizq_stream, pid, {:connected, url}}`
    * `{:zizq_stream, pid, {:job, %Zizq.Job{}}}`
    * `{:zizq_stream, pid, {:disconnected, reason}}` — reason is a
      `Zizq.Error` or `:closed` for a clean end of stream

  ## Flow control

  The server sends at most `:prefetch` unacknowledged jobs before it
  pauses, so acknowledging is what asks for more. That bounds this
  process's mailbox by construction: it cannot be flooded faster than
  jobs are being completed, however far behind the consumer falls.

  ## Reconnection

  Disconnects are expected on a connection meant to live forever, so
  they are retried with exponential backoff rather than crashing the
  process. A response the server will answer identically next time — a
  rejected queue name, say — is not retried; the process stops instead,
  because retrying could only loop.
  """

  use GenServer

  require Logger

  alias Zizq.Config
  alias Zizq.Stream.Framer

  @backoff_ms [250, 500, 1_000, 2_000, 5_000, 10_000]

  @options_schema [
    client: [type: :atom, required: true, doc: "Name of a running `Zizq` client."],
    owner: [type: :pid, doc: "Process to deliver messages to. Defaults to the caller."],
    queues: [
      type: {:list, :string},
      default: [],
      doc: "Queues to take from. Empty means every queue."
    ],
    prefetch: [
      type: :pos_integer,
      doc: """
      Maximum unacknowledged jobs the server will send before pausing.
      Omitted by default, so the server's own default applies.
      """
    ],
    worker_id: [
      type: :string,
      doc: "Identifies this consumer in the server's logs. Assigned by the server if omitted."
    ],
    name: [type: :any, doc: "Optional GenServer name."]
  ]

  @doc """
  Start a stream.

  ## Options

  #{NimbleOptions.docs(@options_schema)}
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = NimbleOptions.validate!(opts, @options_schema)
    {name, opts} = Keyword.pop(opts, :name)
    opts = Keyword.put_new(opts, :owner, self())

    case name do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl GenServer
  def init(opts) do
    state = %{
      config: Config.fetch!(Keyword.fetch!(opts, :client)),
      owner: Keyword.fetch!(opts, :owner),
      queues: Keyword.fetch!(opts, :queues),
      prefetch: Keyword.get(opts, :prefetch),
      worker_id: Keyword.get(opts, :worker_id),
      conn: nil,
      ref: nil,
      framer: nil,
      idle_timer: nil,
      # Set when a non-200 arrives, so the body can be collected and
      # turned into an error naming what the server actually objected to.
      failure: nil,
      attempt: 0
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state), do: connect(state)

  @impl GenServer
  def handle_info(:reconnect, state), do: connect(state)

  # Matched on the timer's own ref, so a timer that had already fired
  # when a chunk arrived cannot tear down the connection that replaced
  # it.
  def handle_info({:idle_timeout, timer}, %{idle_timer: timer} = state) do
    disconnected(state, %Zizq.Error{
      reason: :transport,
      message:
        "take stream received nothing for #{state.config.stream_idle_timeout}ms, " <>
          "not even a heartbeat; treating the connection as dead"
    })
  end

  def handle_info({:idle_timeout, _stale}, state), do: {:noreply, state}

  def handle_info(message, %{conn: conn} = state) when conn != nil do
    case Mint.HTTP.stream(conn, message) do
      {:ok, conn, responses} ->
        # Any traffic counts, heartbeats included — that is what they
        # are for.
        handle_responses(responses, arm_idle_timer(%{state | conn: conn}))

      {:error, conn, reason, _responses} ->
        disconnected(%{state | conn: conn}, Zizq.Error.transport(reason))

      # Not ours — another process's socket message, or a stray timer.
      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{conn: conn}) when conn != nil do
    Mint.HTTP.close(conn)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- Connecting ---

  defp connect(state) do
    uri = state.config.uri

    with {:ok, conn} <-
           Mint.HTTP.connect(scheme(uri), uri.host, uri.port,
             # HTTP/1.1 deliberately, not h2c: this endpoint is one
             # long unidirectional flow of frames, where HTTP/2's
             # per-frame overhead is cost with no multiplexing benefit
             # to offset it. Everything else the client does is h2c.
             protocols: [:http1],
             transport_opts: [timeout: state.config.connect_timeout]
           ),
         {:ok, conn, ref} <- Mint.HTTP.request(conn, "GET", path(state), headers(state), nil) do
      # `:connected` waits for the 200 below rather than firing here.
      # A socket that opens and is then refused at the HTTP layer was
      # never a working stream, and saying otherwise would mean
      # announcing a connection immediately before reporting its
      # failure.
      {:noreply,
       arm_idle_timer(%{
         state
         | conn: conn,
           ref: ref,
           framer: Framer.new(state.config.codec),
           failure: nil
       })}
    else
      {:error, reason} -> disconnected(state, Zizq.Error.transport(reason))
      {:error, conn, reason} -> disconnected(%{state | conn: conn}, Zizq.Error.transport(reason))
    end
  end

  defp scheme(%URI{scheme: "https"}), do: :https
  defp scheme(%URI{}), do: :http

  defp path(state) do
    query =
      %{}
      |> put_param("prefetch", state.prefetch)
      |> put_param("queue", queue_param(state.queues))
      |> URI.encode_query()

    base = (state.config.uri.path || "") <> "/jobs/take"
    if query == "", do: base, else: base <> "?" <> query
  end

  defp put_param(params, _key, nil), do: params
  defp put_param(params, key, value), do: Map.put(params, key, value)

  defp queue_param([]), do: nil
  defp queue_param(queues), do: Enum.join(queues, ",")

  defp headers(state) do
    [{"accept", state.config.codec.stream_content_type()}]
    |> maybe_header("worker-id", state.worker_id)
  end

  defp maybe_header(headers, _name, nil), do: headers
  defp maybe_header(headers, name, value), do: [{name, value} | headers]

  # --- Responses ---

  defp handle_responses([], state), do: {:noreply, state}

  defp handle_responses([response | rest], state) do
    case handle_response(response, state) do
      {:cont, state} -> handle_responses(rest, state)
      {:halt, result} -> result
    end
  end

  defp handle_response({:status, ref, 200}, %{ref: ref} = state) do
    url = Config.url(state.config)
    send_owner(state, {:connected, url})
    Zizq.Telemetry.emit([:stream, :connect], %{client: state.config.name, url: url})

    # Backoff resets here, not on socket connect. A server that accepts
    # connections but rejects every request would otherwise reset the
    # delay each attempt and be hammered at full speed.
    {:cont, %{state | attempt: 0}}
  end

  defp handle_response({:status, ref, status}, %{ref: ref} = state) do
    # Collect the body before reporting: the server explains itself in
    # it, and "server returned 400" alone would not say which option
    # was wrong.
    {:cont, %{state | failure: {status, <<>>}}}
  end

  defp handle_response({:headers, ref, headers}, %{ref: ref} = state) do
    # The response's own content type decides the framing, so a server
    # answering NDJSON to a MessagePack request still decodes.
    codec =
      case List.keyfind(headers, "content-type", 0) do
        {_, value} ->
          case Zizq.Codec.from_content_type(value) do
            {:ok, codec} -> codec
            :error -> state.config.codec
          end

        nil ->
          state.config.codec
      end

    {:cont, %{state | framer: Framer.new(codec)}}
  end

  defp handle_response({:data, ref, data}, %{ref: ref, failure: {status, body}} = state) do
    {:cont, %{state | failure: {status, body <> data}}}
  end

  defp handle_response({:data, ref, data}, %{ref: ref} = state) do
    case Framer.push(state.framer, data) do
      {:ok, records, framer} ->
        Enum.each(records, &send_owner(state, {:job, Zizq.Job.from_wire(&1)}))
        {:cont, %{state | framer: framer}}

      {:error, error} ->
        {:halt, disconnected(state, error)}
    end
  end

  defp handle_response({:done, ref}, %{ref: ref, failure: {status, body}} = state) do
    {:halt, disconnected(state, Zizq.Error.from_response(status, decode_body(state, body)))}
  end

  defp handle_response({:done, ref}, %{ref: ref} = state) do
    # A clean end of body is still a disconnect: the stream is meant to
    # stay open, so the server closing it means reconnect.
    error =
      case Framer.finish(state.framer) do
        :ok -> :closed
        {:error, error} -> error
      end

    {:halt, disconnected(state, error)}
  end

  defp handle_response({:error, ref, reason}, %{ref: ref} = state) do
    {:halt, disconnected(state, Zizq.Error.transport(reason))}
  end

  # A response for a request we are no longer tracking.
  defp handle_response(_response, state), do: {:cont, state}

  defp decode_body(_state, <<>>), do: nil

  defp decode_body(state, body) do
    case state.config.codec.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> nil
    end
  end

  # --- Disconnecting ---

  defp disconnected(state, reason) do
    if state.conn, do: Mint.HTTP.close(state.conn)
    send_owner(state, {:disconnected, reason})
    Zizq.Telemetry.emit([:stream, :disconnect], %{client: state.config.name, reason: reason})

    state = cancel_idle_timer(state)
    state = %{state | conn: nil, ref: nil, framer: nil, failure: nil}

    if retry?(reason) do
      delay = Enum.at(@backoff_ms, state.attempt, List.last(@backoff_ms))

      Logger.warning(
        "[zizq] take stream disconnected, reconnecting in #{delay}ms: #{describe(reason)}"
      )

      Process.send_after(self(), :reconnect, delay)
      {:noreply, %{state | attempt: state.attempt + 1}}
    else
      # Retrying could only produce the same answer, so fail loudly
      # rather than looping against a request the server will always
      # reject.
      {:stop, reason, state}
    end
  end

  defp retry?(:closed), do: true
  defp retry?(%Zizq.Error{} = error), do: Zizq.Error.retryable?(error)

  defp describe(:closed), do: "server closed the stream"
  defp describe(%Zizq.Error{} = error), do: Exception.message(error)

  # A read timeout, not an inactivity budget: the server heartbeats an
  # otherwise idle stream, so silence for this long means the
  # connection is gone rather than merely quiet. Without it a
  # half-open socket — a dropped route, a NAT table expiring — would
  # leave this process waiting for jobs that can never arrive, and no
  # TCP error would ever come.
  #
  # Mint cannot provide this for us. Its only read timeout is on
  # `recv/3`, which works in passive mode alone; in active mode Mint
  # delivers messages and never blocks, so there is nothing to time.
  # That follows from Mint owning no process, and therefore no timer —
  # the reason Finch can offer `receive_timeout` while Mint cannot.
  # Passive mode would block this GenServer inside `recv/3` and leave
  # it unable to answer a shutdown, so the timer lives here.
  defp arm_idle_timer(state) do
    state = cancel_idle_timer(state)
    timer = make_ref()
    Process.send_after(self(), {:idle_timeout, timer}, state.config.stream_idle_timeout)
    %{state | idle_timer: timer}
  end

  defp cancel_idle_timer(%{idle_timer: nil} = state), do: state
  defp cancel_idle_timer(state), do: %{state | idle_timer: nil}

  defp send_owner(state, message), do: send(state.owner, {:zizq_stream, self(), message})
end
