# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.FakeServer do
  @moduledoc false
  # An in-process HTTP server for tests, so response handling can be
  # exercised without the integration harness and its real server
  # binary.
  #
  # Bandit rather than Bypass: Bypass is Cowboy-backed and speaks only
  # HTTP/1.1, but this client's pool is `protocols: [:http2]`, so
  # Bypass cannot answer it at all. Bandit serves HTTP/2 with prior
  # knowledge over a plain `:http` listener, which is exactly the
  # transport the client uses in production.
  #
  # The full round trip runs for real — Finch, Mint, h2c framing, HPACK
  # — and only the origin is faked. That is deliberate: mocking at the
  # Finch boundary instead would stub out the part most likely to
  # surprise us.

  @behaviour Plug

  @impl Plug
  def init(handler), do: handler

  @impl Plug
  def call(conn, handler), do: handler.(conn)

  @doc """
  Start a server for the current test and return its base URL.

  `handler` is a one-argument function receiving a `Plug.Conn` and
  returning a sent one. The server is supervised by ExUnit, so it stops
  when the test ends.

      url = FakeServer.start!(fn conn ->
        Plug.Conn.send_resp(conn, 404, ~s({"error":"nope"}))
      end)
  """
  @spec start!((Plug.Conn.t() -> Plug.Conn.t())) :: String.t()
  def start!(handler) when is_function(handler, 1) do
    pid =
      ExUnit.Callbacks.start_supervised!(
        {
          Bandit,
          # Long-lived streaming connections would otherwise hold
          # teardown open for ThousandIsland's default drain period,
          # which dwarfs the tests themselves. Nothing here needs a
          # graceful close.
          plug: {__MODULE__, handler},
          scheme: :http,
          port: 0,
          startup_log: false,
          thousand_island_options: [shutdown_timeout: 0]
        },
        id: {__MODULE__, System.unique_integer([:positive])}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}"
  end

  @doc """
  Start a server and a `Zizq` client pointed at it, returning the
  client's name.

  Covers the common case where a test only cares about what the client
  does with a given response.
  """
  @spec start_client!((Plug.Conn.t() -> Plug.Conn.t()), keyword()) :: atom()
  def start_client!(handler, opts \\ []) do
    url = start!(handler)
    name = :"zizq_fake_#{System.unique_integer([:positive])}"

    ExUnit.Callbacks.start_supervised!({Zizq, [name: name, url: url] ++ opts})

    name
  end

  @doc """
  Start a client whose server answers everything a worker asks of it.

  Returns the client's name. The test receives:

    * `{:stream, server_pid}` when the take stream is opened. Send it
      `{:emit, bytes}` to push bytes down the stream, or `:stop` to
      close it. `emit_job/3` covers the usual case.
    * `{:ack, path, body}` for every acknowledgement, decoded.

  Every endpoint answers as the real server does, rather than as the
  test in front of it happens to need. A stub that under-responds does
  not fail the test that wrote it — the client reports the problem
  from the acker's process, often after the test has finished, so it
  surfaces as an error logged during some unrelated run.
  """
  @spec start_worker_client!(keyword()) :: atom()
  def start_worker_client!(opts \\ []) do
    test_pid = self()

    start_client!(&worker_handler(&1, test_pid), Keyword.put_new(opts, :format, :json))
  end

  defp worker_handler(conn, test_pid) do
    case conn.request_path do
      "/jobs/take" ->
        send(test_pid, {:stream, self()})

        conn
        |> Plug.Conn.send_chunked(200)
        |> stream_loop()

      "/jobs/success" ->
        acknowledge(conn, test_pid, 204, nil, "")

      path ->
        if String.ends_with?(path, "/failure") do
          # A failure report answers with the job as the server leaves
          # it — rescheduled, with the attempt counted — not a 204. A
          # 204 here makes the acker log that it could not report,
          # from its own process, long after the test has moved on.
          body = job_json(job_id(path), %{"status" => "scheduled", "attempts" => 1})
          acknowledge(conn, test_pid, 200, "application/json", body)
        else
          unexpected(conn, test_pid, path)
        end
    end
  end

  defp stream_loop(conn) do
    receive do
      {:emit, bytes} ->
        case Plug.Conn.chunk(conn, bytes) do
          {:ok, conn} -> stream_loop(conn)
          {:error, :closed} -> conn
        end

      :stop ->
        conn
    after
      5_000 -> conn
    end
  end

  defp acknowledge(conn, test_pid, status, content_type, body) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    send(test_pid, {:ack, conn.request_path, if(raw == "", do: nil, else: JSON.decode!(raw))})

    respond(conn, status, content_type, body)
  end

  # Loud rather than plausible: answering 204 to anything unrecognised
  # is how a stub silently stops resembling the server.
  defp unexpected(conn, test_pid, path) do
    send(test_pid, {:unexpected_request, path})

    respond(conn, 500, "application/json", ~s({"error":"unexpected request to #{path}"}))
  end

  defp job_id(path) do
    path |> String.split("/") |> Enum.at(2)
  end

  @doc """
  JSON for one job, as the take stream frames it — newline-terminated.
  """
  @spec job_json(String.t(), map()) :: String.t()
  def job_json(id, overrides \\ %{}) do
    %{
      "id" => id,
      "type" => "probe",
      "queue" => "default",
      "status" => "in_flight",
      "payload" => %{},
      "attempts" => 0
    }
    |> Map.merge(overrides)
    |> JSON.encode!()
  end

  @doc """
  Push one job down an open take stream.
  """
  @spec emit_job(pid(), String.t(), map()) :: :ok
  def emit_job(server, id, overrides \\ %{}) do
    send(server, {:emit, job_json(id, overrides) <> "\n"})
    :ok
  end

  @doc """
  Send a response with an explicit content type.

  `Plug.Conn.put_resp_content_type/2` appends `; charset=utf-8`, which
  is legitimate but obscures whether the client parses media type
  parameters; this sets the header verbatim.
  """
  @spec respond(Plug.Conn.t(), non_neg_integer(), String.t() | nil, iodata()) :: Plug.Conn.t()
  def respond(conn, status, content_type, body) do
    conn
    |> then(fn conn ->
      if content_type do
        Plug.Conn.put_resp_header(conn, "content-type", content_type)
      else
        conn
      end
    end)
    |> Plug.Conn.send_resp(status, body)
  end
end
