# Telemetry

The client emits [`:telemetry`](https://hexdocs.pm/telemetry) events for jobs,
enqueues and the worker's take stream. Nothing needs configuring, and there is
no cost beyond the emit when nothing is attached — so these are always on,
whether or not you use them.

> Elixir:
>
> ```elixir
> :telemetry.attach_many(
>   "zizq-logger",
>   [[:zizq, :job, :stop], [:zizq, :job, :exception]],
>   &MyApp.Telemetry.handle/4,
>   nil
> )
> ```

Attach in your application's `start/2`, before the client and workers start,
so nothing is missed.

## Event shapes

Events come in two shapes:

- **Spans** emit `:start`, then exactly one of `:stop` or `:exception`, and
  carry `:duration` in native units.
- **Single events** emit once, with `:system_time`.

> [!WARNING]
> `:telemetry.span/3` does **not** merge a span's start metadata into its stop
> event. Each event's metadata is listed below in full — read `:stop` as
> carrying what is listed there, not that plus `:start`'s.

Convert a duration for display with `System.convert_time_unit/3`:

> Elixir:
>
> ```elixir
> System.convert_time_unit(measurements.duration, :native, :millisecond)
> ```

## Job events

### `[:zizq, :job, :start | :stop | :exception]`

One span per job, emitted in the task the job runs in. Metadata on every
event:

Key | Value
--- | ---
`:worker` | the worker's name
`:id` | the job's id
`:type` | the job's type
`:queue` | the queue it came from
`:attempts` | attempts already finished, so `0` on a first run

`:stop` adds `:outcome`, which is what the handler's return value was
understood as:

`:outcome` | Handler returned
--- | ---
`:ok` | `:ok` or `{:ok, term}`
`:error` | `{:error, reason}`
`:cancel` | `{:cancel, reason}`
`:snooze` | `{:snooze, _}`
`:unknown` | anything else — acknowledged, and warned about

A handler that raises, exits or is killed produces `:exception` instead, with
`:kind`, `:reason` and `:stacktrace`.

> [!IMPORTANT]
> Between them, `:stop` and `:exception` cover every job. **Counting `:stop`
> alone undercounts** — and it undercounts precisely the jobs you most want to
> know about, since a crashed handler never reaches `:stop`.

A logger covering both:

> Elixir:
>
> ```elixir
> defmodule MyApp.Telemetry do
>   require Logger
>
>   def handle([:zizq, :job, :stop], %{duration: duration}, meta, _config) do
>     ms = System.convert_time_unit(duration, :native, :millisecond)
>     Logger.info("#{meta.type} #{meta.id} #{meta.outcome} in #{ms}ms")
>   end
>
>   def handle([:zizq, :job, :exception], _measurements, meta, _config) do
>     Logger.error("#{meta.type} #{meta.id} crashed: #{Exception.format(meta.kind, meta.reason, meta.stacktrace)}")
>   end
> end
> ```

## Enqueue events

### `[:zizq, :enqueue, :start | :stop | :exception]`

One span **per call, not per job** — a bulk enqueue of a thousand jobs is one
request and one span. Metadata on every event:

Key | Value
--- | ---
`:client` | the client's name
`:count` | jobs in the request
`:type` | the job's type, or `nil` for a bulk enqueue
`:queue` | the job's queue, or `nil` for a bulk enqueue

`:type` and `:queue` are `nil` for a bulk enqueue because its jobs need not
agree on either.

`:stop` adds `:outcome` — `:ok` or `:error` — and `:error` carries the
`Zizq.Error` when it was the latter.

> [!IMPORTANT]
> A rejected enqueue **returns** an error rather than raising, so it is a
> `:stop` with `outcome: :error`, not an `:exception`. Count both
> `:exception` and `outcome: :error` to catch every failure.

## Stream events

### `[:zizq, :stream, :connect]`

The worker's take stream got its `200`, so the server has accepted the request
and jobs will follow. Metadata: `:client` and `:url`.

### `[:zizq, :stream, :disconnect]`

The worker's take stream lost its connection, for any reason including a clean
shutdown. Metadata: `:client`, and `:reason` — a `Zizq.Error` or `:closed`.

> [!NOTE]
> Reconnection is automatic for anything retryable, so disconnects are
> **expected in normal operation**. Alert on their rate rather than on their
> occurrence — one disconnect is a network; a hundred a minute is a problem.

## With Telemetry.Metrics

These events are ordinary `:telemetry` events, so
[`Telemetry.Metrics`](https://hexdocs.pm/telemetry_metrics) works without
anything in between:

> Elixir:
>
> ```elixir
> import Telemetry.Metrics
>
> def metrics do
>   [
>     # How long jobs take, split by type and outcome.
>     distribution("zizq.job.stop.duration",
>       unit: {:native, :millisecond},
>       tags: [:type, :outcome]
>     ),
>
>     # Crashes, which never reach :stop.
>     counter("zizq.job.exception.duration", tags: [:type, :queue]),
>
>     # Enqueue latency, per client.
>     summary("zizq.enqueue.stop.duration",
>       unit: {:native, :millisecond},
>       tags: [:client]
>     ),
>
>     # Stream health.
>     counter("zizq.stream.disconnect.system_time", tags: [:client])
>   ]
> end
> ```

Tags must be metadata keys the event actually carries, which is where the
"start metadata is not merged" caveat bites: tagging a `:stop` metric with a
key only `:start` carries silently produces `nil` tags.

## What is not emitted

There is no event per **acknowledgement**. Acks are batched by the worker and
flushed together, so an event per ack would say more about the batching than
about the jobs. The job span already covers the work; a slow flush shows up as
back-pressure on the worker rather than as an event.

There is likewise no event for ordinary reads — `get_job/2`, `list_jobs/2`
and the rest are plain request/response calls with nothing to correlate.

## Where to see it live

For watching a queue rather than instrumenting one, `zizq top` reads the
server's admin API directly and needs nothing from the client:

> Command:
>
> ```bash
> $ zizq top
> ```

That shows queue depths, in-flight jobs and throughput across every worker in
every language, which telemetry from one application cannot.
