# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Worker.Acker do
  @moduledoc """
  Acknowledges completed work, batching successes into single requests.

  Normally started for you by `Zizq.Worker`. Use it directly only if
  you are driving `Zizq.Stream.Take` yourself.

      {:ok, acker} = Zizq.Worker.Acker.start_link(client: MyApp.Zizq)

      Zizq.Worker.Acker.success(acker, job)
      Zizq.Worker.Acker.failure(acker, job, message: "SMTP timeout")

  Both are asynchronous: a handler should not wait on a network round
  trip it has no use for, and acknowledgement is not something the
  handler can meaningfully recover from.

  ## Batching never delays an acknowledgement

  There is no timer. A success is buffered and a flush is queued to
  this process immediately, which lands behind everything already in
  the mailbox — so a burst of completions collapses into one request
  while a lone completion goes out on its own, without waiting for
  company.

  Batching then grows with load rather than with a clock: while a
  request is in flight the process is busy, so acknowledgements
  arriving meanwhile accumulate and leave together in the next one.

  A flush interval would be actively harmful here. Prefetch is
  released *by* acknowledgement, so holding acknowledgements back to
  fill a batch throttles the throughput the batching is meant to
  serve.

  ## Why successes batch and failures do not

  A success carries nothing but an id, so a hundred of them fit in one
  request. Since the server's prefetch is released by acknowledgement,
  batching them directly raises how fast work can be pulled.

  A failure carries a message, an error type and a stack trace that
  belong to one job, and the server responds with that job's new state.
  There is nothing to combine and failures are lower volume than
  successes, so failures go one at a time.

  ## Losing acknowledgements is safe, but wasteful

  In the case of a crashed worker an unacknowledged job is redelivered
  after the server detects the dead worker connection, so a dropped
  acknowledgement costs duplicated work rather than lost work. That is
  why transient failures are retried with backoff and permanent ones
  are logged and dropped: retrying a 4xx could only produce the same
  answer, and blocking on it would stall every acknowledgement behind
  it.
  """

  use GenServer

  require Logger

  @options_schema [
    client: [type: :atom, required: true, doc: "Name of a running `Zizq` client."],
    max_batch: [
      type: :pos_integer,
      default: 1_000,
      doc: """
      Most ids to put in a single request. A cap on request size, not a
      trigger: a larger buffer is split across requests sent one after
      another, never held back waiting to fill.

      Rarely reached. A job stays in flight until it is acknowledged,
      so the buffer cannot exceed the worker's prefetch — this only
      applies at a prefetch above the cap, or while a backlog is being
      retried through an outage. It is here to bound request size in
      those cases rather than to shape ordinary batching.
      """
    ],
    name: [type: :any, doc: "Optional GenServer name."]
  ]

  @retry_backoff_ms [100, 250, 500, 1_000, 2_500, 5_000]

  @doc """
  Start an acker.

  ## Options

  #{NimbleOptions.docs(@options_schema)}
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = NimbleOptions.validate!(opts, @options_schema)
    {name, opts} = Keyword.pop(opts, :name)

    case name do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Record a job as completed. Buffered, then sent with others."
  @spec success(GenServer.server(), Zizq.Job.t() | String.t()) :: :ok
  def success(acker, job), do: GenServer.cast(acker, {:success, id(job)})

  @doc """
  Record a job as failed. Sent on its own.

  Takes the same options as `Zizq.report_failure/3`, including `:kill`
  and `:retry_at`.
  """
  @spec failure(GenServer.server(), Zizq.Job.t() | String.t(), keyword()) :: :ok
  def failure(acker, job, opts), do: GenServer.cast(acker, {:failure, id(job), opts})

  @doc """
  Send everything buffered and wait for it.

  Called during shutdown, while the take stream is still open so the
  server will still accept the acknowledgements. Returns `:ok` even if
  some could not be sent — they will be redelivered, and refusing to
  shut down over it would be worse.
  """
  @spec flush(GenServer.server(), timeout()) :: :ok
  def flush(acker, timeout \\ 5_000), do: GenServer.call(acker, {:flush, timeout}, :infinity)

  @doc "How many successes are waiting to be sent."
  @spec pending(GenServer.server()) :: non_neg_integer()
  def pending(acker), do: GenServer.call(acker, :pending)

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       client: Keyword.fetch!(opts, :client),
       max_batch: Keyword.fetch!(opts, :max_batch),
       # Newest first; reversed when sent, so buffering stays O(1).
       buffer: [],
       flush_queued?: false,
       attempt: 0
     }}
  end

  @impl GenServer
  def handle_cast({:success, id}, state) do
    {:noreply, queue_flush(%{state | buffer: [id | state.buffer]})}
  end

  def handle_cast({:failure, id, opts}, state) do
    report_failure(state, id, opts, @retry_backoff_ms)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:flush, timeout}, _from, state) do
    deadline = System.monotonic_time(:millisecond) + timeout
    {:reply, :ok, drain(state, deadline)}
  end

  def handle_call(:pending, _from, state), do: {:reply, length(state.buffer), state}

  @impl GenServer
  def handle_info(:flush, state), do: {:noreply, send_buffer(%{state | flush_queued?: false})}

  def handle_info(:retry, state), do: {:noreply, send_buffer(state)}

  # --- Successes ---

  defp send_buffer(%{buffer: []} = state), do: %{state | attempt: 0}

  defp send_buffer(state) do
    case attempt_send(state) do
      {:sent, state} ->
        state

      {:retryable, state, error} ->
        delay = Enum.at(@retry_backoff_ms, state.attempt, List.last(@retry_backoff_ms))

        Logger.warning(
          "[zizq] could not acknowledge #{length(state.buffer)} job(s), " <>
            "retrying in #{delay}ms: " <> Exception.message(error)
        )

        Process.send_after(self(), :retry, delay)
        %{state | attempt: state.attempt + 1}

      {:dropped, state} ->
        state
    end
  end

  # Sends one chunk and reports what happened, without deciding *when*
  # to try again. Kept separate because the two callers differ on that:
  # the asynchronous path schedules a timer, while `drain/2` retries
  # inline. Scheduling from both left a timer behind on every drain
  # iteration, and those fired afterwards to re-send a batch that had
  # already been given up on.
  defp attempt_send(state) do
    {ids, rest} = state.buffer |> Enum.reverse() |> Enum.split(state.max_batch)

    case Zizq.report_success_all(ids, state.client) do
      {:ok, not_found} ->
        log_not_found(not_found)
        state = %{state | buffer: Enum.reverse(rest), attempt: 0}
        # Anything over the cap goes straight into another request
        # rather than waiting for a trigger.
        {:sent, if(rest == [], do: state, else: queue_flush(state))}

      {:error, error} ->
        if Zizq.Error.retryable?(error) do
          # The buffer is left intact, so the next attempt re-sends the
          # same chunk along with anything that arrived meanwhile.
          {:retryable, state, error}
        else
          # Retrying could only produce the same answer. The jobs are
          # redelivered after their visibility timeout, so this costs
          # repeated work rather than lost work. Only the attempted
          # chunk is dropped.
          Logger.error(
            "[zizq] dropping #{length(ids)} acknowledgement(s): " <> Exception.message(error)
          )

          state = %{state | buffer: Enum.reverse(rest), attempt: 0}
          {:dropped, if(rest == [], do: state, else: queue_flush(state))}
        end
    end
  end

  # Queued to this process rather than scheduled on a timer. A
  # self-sent message lands behind everything already in the mailbox,
  # so every acknowledgement queued up to this point joins the same
  # batch, and none of them waits on a clock.
  defp queue_flush(%{flush_queued?: true} = state), do: state

  defp queue_flush(state) do
    send(self(), :flush)
    %{state | flush_queued?: true}
  end

  # Already acknowledged, or redelivered elsewhere after a visibility
  # timeout. Nothing to do, but worth saying so.
  defp log_not_found([]), do: :ok

  defp log_not_found(ids) do
    Logger.debug("[zizq] #{length(ids)} acknowledged job(s) were no longer in flight")
  end

  # --- Failures ---

  defp report_failure(state, id, opts, backoff) do
    case Zizq.report_failure(id, state.client, opts) do
      {:ok, _job} ->
        :ok

      {:error, error} ->
        case {Zizq.Error.retryable?(error), backoff} do
          {true, [delay | rest]} ->
            Process.sleep(delay)
            report_failure(state, id, opts, rest)

          _ ->
            Logger.error(
              "[zizq] could not report failure for job #{id}: " <> Exception.message(error)
            )
        end
    end
  end

  # --- Shutdown ---

  # Retries inline rather than by timer: the caller is waiting, and a
  # scheduled retry would arrive after this process has gone.
  defp drain(%{buffer: []} = state, _deadline), do: state

  defp drain(state, deadline) do
    # `attempt_send/1` rather than `send_buffer/1`: no timer is left
    # behind for a retry this loop is already performing itself.
    state =
      case attempt_send(state) do
        {:sent, state} -> state
        {:dropped, state} -> state
        {:retryable, state, _error} -> state
      end

    cond do
      state.buffer == [] ->
        state

      System.monotonic_time(:millisecond) >= deadline ->
        Logger.warning(
          "[zizq] shutting down with #{length(state.buffer)} unacknowledged job(s); " <>
            "they will be redelivered"
        )

        state

      true ->
        Process.sleep(50)
        drain(state, deadline)
    end
  end

  defp id(%Zizq.Job{id: id}), do: id
  defp id(id) when is_binary(id), do: id
end
