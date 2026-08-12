# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Worker.Runner do
  @moduledoc false
  # Owns the take stream, runs each job in its own supervised task, and
  # turns whatever the handler returns into an acknowledgement or
  # failure.
  #
  # Started by `Zizq.Worker`; see docs for the public options.
  #
  # Every job runs in a task rather than directly in the Runner, so a
  # handler that raises, exits, or is killed outright cannot take the
  # worker down with it — the crash arrives as a `:DOWN` message and
  # becomes a failure report like any other. It also means a slow
  # handler never blocks the stream from being read.

  use GenServer

  require Logger

  alias Zizq.Worker.Acker

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl GenServer
  def init(opts) do
    # Needed for `terminate/2` to run on shutdown, which is where the
    # drain happens.
    Process.flag(:trap_exit, true)

    state = %{
      client: Keyword.fetch!(opts, :client),
      # Compiled once here rather than per job, so dispatching through
      # a router costs exactly what dispatching through a plain
      # function does.
      handler: to_handler(Keyword.fetch!(opts, :handler)),
      worker: Keyword.fetch!(opts, :worker),
      acker: Keyword.fetch!(opts, :acker),
      tasks: Keyword.fetch!(opts, :tasks),
      concurrency: Keyword.fetch!(opts, :concurrency),
      drain_timeout: Keyword.fetch!(opts, :drain_timeout),
      stream: nil,
      # ref => job, for jobs currently running.
      running: %{},
      # Jobs delivered while every slot was busy. Bounded by prefetch,
      # since the server sends no more than that unacknowledged.
      queued: :queue.new()
    }

    stream_opts =
      [client: state.client, owner: self()]
      |> put_opt(:queues, Keyword.get(opts, :queues))
      |> put_opt(:prefetch, Keyword.get(opts, :prefetch))
      |> put_opt(:worker_id, Keyword.get(opts, :worker_id))

    {:ok, stream} = Zizq.Stream.Take.start_link(stream_opts)

    {:ok, %{state | stream: stream}}
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp to_handler(%Zizq.Router{} = router), do: Zizq.Router.build(router)
  defp to_handler(fun) when is_function(fun, 1), do: fun

  @impl GenServer
  def handle_info({:zizq_stream, stream, message}, %{stream: stream} = state) do
    {:noreply, handle_stream(message, state)}
  end

  # A task finished and returned a value.
  def handle_info({ref, result}, %{running: running} = state)
      when is_map_key(running, ref) do
    Process.demonitor(ref, [:flush])
    {job, running} = Map.pop(running, ref)

    acknowledge(state, job, result)
    {:noreply, start_next(%{state | running: running})}
  end

  # A task crashed. `async_nolink` means this reaches us as a message
  # rather than an exit signal, so the worker survives it.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running: running} = state)
      when is_map_key(running, ref) do
    {job, running} = Map.pop(running, ref)

    Acker.failure(state.acker, job, failure_from_exit(reason))
    {:noreply, start_next(%{state | running: running})}
  end

  # The stream gave up — a request the server will always reject. There
  # is no work without it, so stop and let the supervisor decide.
  def handle_info({:EXIT, stream, reason}, %{stream: stream} = state) do
    {:stop, reason, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    # Ordering matters, and it is the reason this process is the last
    # child started and so the first stopped:
    #
    #   1. stop taking new work (the stream is still open, so the
    #      server keeps our in-flight jobs and will accept acks)
    #   2. let running jobs finish
    #   3. flush the acker, which is still alive behind us
    #   4. return, at which point the linked stream closes
    #
    # Closing the stream first would have the server redeliver
    # everything still in flight, duplicating work that was about to
    # finish.
    #
    # The deadline sits just inside the supervisor's own limit, which
    # is exactly `:drain_timeout`. Running to the very edge would risk
    # being brutally killed part-way through the flush, losing
    # acknowledgements for work that had already finished.
    deadline = System.monotonic_time(:millisecond) + budget(state.drain_timeout)

    state = drain(state, deadline)

    remaining = max(0, deadline - System.monotonic_time(:millisecond))
    Acker.flush(state.acker, remaining)

    :ok
  end

  defp budget(timeout), do: timeout - min(div(timeout, 20), 250)

  # --- Stream messages ---

  defp handle_stream({:job, job}, state), do: dispatch(job, state)

  defp handle_stream({:connected, url}, state) do
    Logger.info("[zizq] worker connected to #{url}")
    state
  end

  defp handle_stream({:disconnected, :closed}, state), do: state

  defp handle_stream({:disconnected, _error}, state), do: state

  # --- Dispatch ---

  defp dispatch(job, state) do
    if map_size(state.running) < state.concurrency do
      start_job(job, state)
    else
      %{state | queued: :queue.in(job, state.queued)}
    end
  end

  defp start_next(state) do
    case :queue.out(state.queued) do
      {{:value, job}, queued} -> start_job(job, %{state | queued: queued})
      {:empty, _} -> state
    end
  end

  defp start_job(job, state) do
    handler = state.handler

    meta = %{
      worker: state.worker,
      id: job.id,
      type: job.type,
      queue: job.queue,
      attempts: job.attempts
    }

    task =
      Task.Supervisor.async_nolink(
        state.tasks,
        # Spanned inside the task, so a handler that raises produces
        # `:exception` rather than `:stop` and the duration covers the
        # handler alone, not the wait for a free slot.
        fn ->
          Zizq.Telemetry.span([:job], meta, fn ->
            result = handler.(job)
            # The whole map, not just the outcome: `span/3` replaces
            # the start metadata rather than merging into it.
            {result, Map.put(meta, :outcome, outcome(result))}
          end)
        end,
        # Short on purpose. A task is only killed once the runner's
        # drain has already given it the full drain timeout and decided
        # to abandon it, so waiting out the 5s default would delay
        # shutdown for a job being redelivered regardless. This second
        # is for the handler's own cleanup, not for its work.
        shutdown: 1_000
      )

    %{state | running: Map.put(state.running, task.ref, job)}
  end

  # --- Results ---

  defp acknowledge(state, job, :ok), do: Acker.success(state.acker, job)
  defp acknowledge(state, job, {:ok, _value}), do: Acker.success(state.acker, job)

  defp acknowledge(state, job, {:error, reason}) do
    Acker.failure(state.acker, job, message: describe(reason))
  end

  defp acknowledge(state, job, {:cancel, reason}) do
    Acker.failure(state.acker, job, message: describe(reason), kill: true)
  end

  defp acknowledge(state, job, {:snooze, milliseconds}) when is_integer(milliseconds) do
    retry_at = DateTime.add(DateTime.utc_now(), milliseconds, :millisecond)

    Acker.failure(state.acker, job,
      message: "snoozed for #{milliseconds}ms",
      retry_at: retry_at
    )
  end

  # An explicit instant, for when "not before this time" is what is
  # actually meant and no arithmetic should be involved.
  defp acknowledge(state, job, {:snooze, %DateTime{} = retry_at}) do
    Acker.failure(state.acker, job,
      message: "snoozed until #{DateTime.to_iso8601(retry_at)}",
      retry_at: retry_at
    )
  end

  # Anything else is acknowledged as complete, and complained about.
  #
  # Both halves matter. Failing the job would be worse than accepting
  # it: the handler most likely did its work and simply ended on the
  # wrong value, so failing would re-run a side effect that already
  # happened. But completing it silently would bury a real mistake —
  # `:error` in place of `{:error, reason}`, or a misspelled tag —
  # under a queue that looks perfectly healthy.
  defp acknowledge(state, job, other) do
    Logger.warning("""
    [zizq] expected the handler for job #{job.id} (#{job.type}) to return one of:

      :ok
      {:ok, value}
      {:error, reason}
      {:cancel, reason}
      {:snooze, milliseconds}
      {:snooze, %DateTime{}}

    Instead received:

    #{inspect(other, pretty: true)}

    The job has been acknowledged as complete.
    """)

    Acker.success(state.acker, job)
  end

  # What the handler's return value was understood as, reported on
  # `[:zizq, :job, :stop]` so a counter needs no second opinion about
  # which returns are failures.
  defp outcome(:ok), do: :ok
  defp outcome({:ok, _value}), do: :ok
  defp outcome({:error, _reason}), do: :error
  defp outcome({:cancel, _reason}), do: :cancel
  defp outcome({:snooze, milliseconds}) when is_integer(milliseconds), do: :snooze
  defp outcome({:snooze, %DateTime{}}), do: :snooze
  defp outcome(_other), do: :unknown

  defp describe(reason) when is_binary(reason), do: reason

  defp describe(reason) do
    if is_exception(reason), do: Exception.message(reason), else: inspect(reason)
  end

  # A raise arrives as `{exception, stacktrace}`; a throw or exit as
  # something else. Both should reach the server as a readable message.
  defp failure_from_exit({exception, stacktrace}) when is_list(stacktrace) do
    if is_exception(exception) do
      [
        message: Exception.message(exception),
        error_type: inspect(exception.__struct__),
        backtrace: Exception.format_stacktrace(stacktrace)
      ]
    else
      [
        message: Exception.format_exit({exception, stacktrace}),
        error_type: "exit",
        backtrace: Exception.format_stacktrace(stacktrace)
      ]
    end
  end

  defp failure_from_exit(reason) do
    [message: Exception.format_exit(reason), error_type: "exit"]
  end

  # --- Shutdown ---

  defp drain(state, deadline) do
    cond do
      map_size(state.running) == 0 and :queue.is_empty(state.queued) ->
        state

      System.monotonic_time(:millisecond) >= deadline ->
        Logger.warning(
          "[zizq] shutting down with #{map_size(state.running)} job(s) still running; " <>
            "they will be redelivered"
        )

        state

      true ->
        # Keep handling task results while draining, so completions
        # still reach the acker and queued jobs still start.
        #
        # This selective receive is also what stops new work being
        # picked up, and it is worth spelling out because no branch
        # here says so. `terminate/2` runs after the GenServer loop has
        # exited, so `handle_info/2` is never called again; only the two
        # patterns below are taken from the mailbox. Jobs the server
        # pushes during the drain — and it will, since the acks we send
        # free up prefetch slots — match neither, so they sit unread and
        # die with the process. `start_next/1` can only draw on jobs
        # already queued before shutdown began.
        receive do
          {ref, result} when is_map_key(state.running, ref) ->
            Process.demonitor(ref, [:flush])
            {job, running} = Map.pop(state.running, ref)
            acknowledge(state, job, result)
            drain(start_next(%{state | running: running}), deadline)

          {:DOWN, ref, :process, _pid, reason} when is_map_key(state.running, ref) ->
            {job, running} = Map.pop(state.running, ref)
            Acker.failure(state.acker, job, failure_from_exit(reason))
            drain(start_next(%{state | running: running}), deadline)
        after
          50 -> drain(state, deadline)
        end
    end
  end
end
