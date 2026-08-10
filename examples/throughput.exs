# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# A crude but effective benchmark: enqueue N no-op jobs, then time how
# long a worker takes to drain them all. The payload is the job's index,
# so the worker knows the run is over when it sees the last one.
#
#     mix run examples/throughput.exs
#
# Environment:
#
#   ZIZQ_URL     server to talk to     (default http://127.0.0.1:7890)
#   ZIZQ_FORMAT  json or msgpack       (default msgpack, the client default)
#   JOB_COUNT    jobs to enqueue       (default 10_000)
#   CONCURRENCY  jobs running at once  (default 25)
#   PREFETCH     unacked jobs in hand  (default twice CONCURRENCY)
#
# Unlike the other clients' versions, this one does not clear or report
# jobs left over from an earlier run — the query and bulk-delete
# endpoints are not implemented here yet. Until they are, compare runs
# against a fresh database, or an earlier run's leftovers will be
# dequeued as part of this one and flatter the result.

# `elixir examples/throughput.exs` starts a bare VM with neither this
# project nor its dependencies on the code path, and the failure that
# follows names `Zizq` rather than the mistake.
unless Code.ensure_loaded?(Zizq) do
  IO.puts(:stderr, "Run this with mix, so the project and its deps are loaded:\n")
  IO.puts(:stderr, "    mix run examples/throughput.exs\n")
  System.halt(1)
end

url = System.get_env("ZIZQ_URL", "http://127.0.0.1:7890")

format =
  case System.get_env("ZIZQ_FORMAT", "msgpack") do
    "msgpack" -> :msgpack
    "json" -> :json
    other -> raise "ZIZQ_FORMAT must be msgpack or json, got: #{inspect(other)}"
  end

job_count = String.to_integer(System.get_env("JOB_COUNT", "10000"))
concurrency = String.to_integer(System.get_env("CONCURRENCY", "25"))
prefetch = String.to_integer(System.get_env("PREFETCH", to_string(concurrency * 2)))

queue = "elixir/bench"

{:ok, _} = Zizq.start_link(name: Bench.Client, url: url, format: format)

seconds_since = fn started ->
  (System.monotonic_time(:microsecond) - started) / 1_000_000
end

report = fn verb, count, elapsed ->
  :io.format("~s ~b jobs in ~.3fs (~.1f jobs/sec)~n", [verb, count, elapsed, count / elapsed])
end

# --- Enqueue phase ---

enqueue_started = System.monotonic_time(:microsecond)

1..job_count
|> Stream.chunk_every(1_000)
|> Enum.each(fn batch ->
  batch
  |> Enum.map(&[type: "bench", queue: queue, payload: &1])
  |> Zizq.enqueue_all!(Bench.Client)
end)

report.("Enqueued", job_count, seconds_since.(enqueue_started))

# --- Dequeue phase ---

bench = self()

# Stopping the worker from inside the handler would deadlock: the
# handler runs in a task supervised by the worker itself, and
# `Supervisor.stop/1` blocks until that supervisor has stopped — which
# it cannot do until the drain finishes, which is waiting on this very
# task. So the handler only sends word, and the stop happens out here.
handler = fn job ->
  if job.queue == queue and job.type == "bench" and job.payload == job_count do
    send(bench, :last_job)
  end

  :ok
end

# Started before the worker, so connecting and streaming count towards
# the time rather than being excluded from it.
dequeue_started = System.monotonic_time(:microsecond)

{:ok, worker} =
  Zizq.Worker.start_link(
    client: Bench.Client,
    name: Bench.Worker,
    queues: [queue],
    concurrency: concurrency,
    prefetch: prefetch,
    handler: handler
  )

receive do
  :last_job -> :ok
after
  :timer.minutes(5) ->
    raise "gave up waiting for job #{job_count}; is another worker draining #{queue}?"
end

# Includes the drain and the final ack flush, so the number covers
# everything the run actually had to do.
:ok = Supervisor.stop(worker)

report.("Dequeued", job_count, seconds_since.(dequeue_started))
