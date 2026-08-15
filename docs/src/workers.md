# Running Workers

A worker takes jobs from the server and runs them. Add one to your
supervision tree alongside the client:

> Elixir:
>
> ```elixir
> children = [
>   {Zizq, name: MyApp.Zizq, url: "http://127.0.0.1:7890"},
>   {Zizq.Worker,
>    client: MyApp.Zizq,
>    queues: ["emails"],
>    concurrency: 25,
>    handler: Zizq.Router.new([MyApp.SendEmail])}
> ]
> ```

There is no separate worker executable. A worker is an ordinary supervised
process group, so it starts with your application, stops with it, and appears
in observer like anything else.

> [!IMPORTANT]
> The order matters. Children are stopped in reverse, so the client must be
> listed **first** — the worker acknowledges jobs through it while shutting
> down. If the client was shut down first, jobs would be returned to the queue
> as the server detects the disconnect.

## Handlers

`:handler` is what runs each job. It takes a `Zizq.Router`, or any function of
one argument over a `Zizq.Job`:

> Elixir:
>
> ```elixir
> # A router, dispatching by job type.
> handler: Zizq.Router.new([MyApp.SendEmail, MyApp.GenerateReport])
>
> # Or a plain function, if you would rather dispatch yourself.
> handler: fn %Zizq.Job{type: type, payload: payload} ->
>   case type do
>     "send_email" -> MyApp.Mailer.deliver(payload)
>     other -> {:error, "unknown type #{other}"}
>   end
> end
> ```

What a handler returns decides the job's fate — see
[What perform returns](./defining-jobs.md#what-perform-returns). The same
contract applies whether the handler came from a job module or is a bare
function.

> [!TIP]
> Prefer a router or a named capture over an inline `fn` in a supervision
> child spec. An anonymous function captured from a module that is later
> recompiled goes stale, which bites during development with code reloading.

## Routing by job type

`Zizq.Router` builds a handler from job modules, asking each for its `type/0`
so the routing table is built once at startup rather than per job:

> Elixir:
>
> ```elixir
> handler: Zizq.Router.new([MyApp.SendEmail, MyApp.GenerateReport])
> ```

Routes can also be added one at a time, which suits building them
conditionally, and plain functions can be registered if necessary:

> Elixir:
>
> ```elixir
> router =
>   Zizq.Router.new()
>   |> Zizq.Router.route(MyApp.SendEmail)
>   |> Zizq.Router.route("ping", fn _payload -> :ok end)
>   |> Zizq.Router.route("audit", fn payload, job -> MyApp.Audit.record(payload, job.id) end)
>
> # Only in development.
> router = if Mix.env() == :dev, do: Zizq.Router.route(router, MyApp.Debug), else: router
> ```

A registered function takes the payload, or the payload and the job, as you
prefer — the arity is inspected once when it is registered.

Two modules claiming the same type in one list is an error, since that would
be nonsensical. `route/2` and `route/3` **replace** instead, which enables
composability.

### Unrecognised types

A job whose type is in no route raises `Zizq.Router.UnknownJobType`, which the
worker reports as a failure like any other exception, so the job retries, and
dies once its retry limit is spent.

Retrying is usually desirable: deploy-time mishaps or typos, for example, can
be detected in production and remediated while the job is retrying.

Pass a `:fallback` to handle them instead:

> Elixir:
>
> ```elixir
> Zizq.Router.new(modules, fallback: &MyApp.handle_unknown/1)
> ```

The fallback receives the whole `Zizq.Job`, since a payload alone says little
about a job you did not expect.

> [!NOTE]
> Types are registered, never resolved. Turning a wire type into a module at
> runtime would mean calling `String.to_existing_atom/1` on data from the
> queue; building a table from modules your application named itself keeps job
> data as something looked *up*, never something that selects code to run.

### Wrapping a router

A `Zizq.Router` is a struct, not a function, so there is nothing to wrap
directly. `Zizq.Router.build/1` compiles one into the same one-argument
function a plain handler is, which you can then wrap however you like:

> Elixir:
>
> ```elixir
> defmodule MyApp.Jobs do
>   def handler do
>     router = Zizq.Router.new([MyApp.SendEmail, MyApp.GenerateReport])
>     dispatch = Zizq.Router.build(router)
>
>     fn %Zizq.Job{} = job ->
>       Logger.metadata(job_id: job.id, job_type: job.type)
>
>       dispatch.(job)
>     end
>   end
> end
> ```

Pass the wrapper as the worker's `:handler`, since it is now an ordinary
function over a `Zizq.Job`:

> Elixir:
>
> ```elixir
> {Zizq.Worker, client: MyApp.Zizq, queues: ["emails"], handler: MyApp.Jobs.handler()}
> ```

This is not a special mechanism — `Zizq.Router.build/1` is exactly what the
worker calls on a router you hand it directly, so wrapping bypasses nothing.

Three things are worth knowing:

**Return what the handler returned.** The wrapper's return value *is* the
job's outcome, so anything after the dispatch replaces it:

> Elixir:
>
> ```elixir
> # Every job now completes, including the ones that failed.
> fn job ->
>   dispatch.(job)
>   :ok
> end
> ```

Where a wrapper genuinely needs to run something afterwards, `try/after`
keeps the value:

> Elixir:
>
> ```elixir
> fn job ->
>   try do
>     dispatch.(job)
>   after
>     MyApp.Tracing.flush()
>   end
> end
> ```

**Build once, not per job.** Call `build/1` while assembling the handler, as
above, not inside the function:

> Elixir:
>
> ```elixir
> # Rebuilds the routing table on every single job.
> fn job -> around(fn -> Zizq.Router.build(router).(job) end) end
> ```

**It runs in the job's own task.** The handler is invoked inside the
supervised task the job runs in, so `Logger` metadata, process-dictionary
state and anything else process-scoped is set where you would want it — and
needs no cleanup, since the task ends with the job.

For behaviour around **one** job type rather than all of them, wrap the route
instead — a router takes plain functions, so nothing else changes:

> Elixir:
>
> ```elixir
> Zizq.Router.route(router, "charge_card", fn payload, job ->
>   MyApp.Billing.with_idempotency(job.id, fn -> MyApp.Billing.charge(payload) end)
> end)
> ```

> [!TIP]
> Timing and outcomes are already emitted as `:telemetry` events — see
> [Telemetry](./telemetry.md). Reach for a wrapper for things telemetry
> cannot do, like setting context a handler reads or wrapping a job in a
> transaction, rather than to measure what is measured for you.

## Isolation

Each job runs in its own supervised task. A handler that raises, exits, or is
killed outright is reported to the server as a failure — with its exception
and stacktrace — and the next job starts. It cannot take the worker down, and
a slow handler cannot block the stream from being read.

> Elixir:
>
> ```elixir
> def perform(_payload), do: raise ArgumentError, "boom"
> ```

That job fails with `error_type: "ArgumentError"` and a formatted backtrace,
readable afterwards with `Zizq.list_errors/3`.

## Concurrency

`:concurrency` is how many jobs the worker can run at once. It defaults to
`10`:

> Elixir:
>
> ```elixir
> {Zizq.Worker, client: MyApp.Zizq, concurrency: 50, handler: router}
> ```

Because each job is a BEAM process rather than an OS thread, this can go far
higher than a thread-pool-based client would tolerate. The useful ceiling is
whatever the work itself imposes — a database pool of 10 connections makes
`concurrency: 100` pointless for jobs that all need one.

### Prefetch

`:prefetch` caps how many unacknowledged jobs the server will send. It
defaults to **twice** `:concurrency`, so a replacement job is already in hand
when one finishes rather than costing a round trip:

> Elixir:
>
> ```elixir
> {Zizq.Worker, client: MyApp.Zizq, concurrency: 25, prefetch: 50, handler: router}
> ```

Raising it buys throughput on fast jobs, though the trade-off is jobs may have
been delivered to the worker that it is not yet running and no other worker can
take. Prefetched jobs are returned the queue automatically like any other job
in the case of an unexpected disconnect. There is no risk of data loss.
Lowering it to `concurrency` removes the at the cost of a round trip between
jobs.

> [!NOTE]
> Prefetch is also what bounds the worker's mailbox. The server reserves a
> slot before dequeuing, so it never sends work the worker has not asked for
> — the classic unbounded-mailbox failure is structurally impossible.

## Which queues to process

`:queues` limits a worker to named queues. Empty — the default — means every
queue:

> Elixir:
>
> ```elixir
> # Only these two.
> {Zizq.Worker, client: MyApp.Zizq, queues: ["emails", "webhooks"], handler: router}
>
> # Everything.
> {Zizq.Worker, client: MyApp.Zizq, handler: router}
> ```

Separate workers give separate concurrency, which is the usual reason to split
them — slow report generation should not starve outbound email:

> Elixir:
>
> ```elixir
> children = [
>   {Zizq, name: MyApp.Zizq, url: "http://127.0.0.1:7890"},
>   {Zizq.Worker,
>    name: MyApp.EmailWorker,
>    client: MyApp.Zizq,
>    queues: ["emails"],
>    concurrency: 50,
>    handler: email_router},
>   {Zizq.Worker,
>    name: MyApp.ReportWorker,
>    client: MyApp.Zizq,
>    queues: ["reports"],
>    concurrency: 2,
>    handler: report_router}
> ]
> ```

> [!IMPORTANT]
> Give each worker a `:name` when running more than one. Without it they all
> default to `Zizq.Worker` and the second fails to start with
> `{:error, {:already_started, _}}`.

Both share the one client, and so one connection pool. Only the job streams
are separate.

## Identifying a worker

`:worker_id` names this worker in the server's logs. The server assigns one if
you leave it out:

> Elixir:
>
> ```elixir
> {Zizq.Worker, client: MyApp.Zizq, worker_id: "email-#{node()}", handler: router}
> ```

## Graceful shutdown

On shutdown the worker stops taking new work, waits for running jobs to
finish, flushes outstanding acknowledgements, and then disconnects, so the
server keeps the in-flight jobs until the acknowledgements arrive.

`:drain_timeout` is the budget for all of that, defaulting to 30 seconds:

> Elixir:
>
> ```elixir
> {Zizq.Worker, client: MyApp.Zizq, drain_timeout: :timer.seconds(45), handler: router}
> ```

It is the **whole** budget, not a per-step one: stopping a worker will not
take materially longer than this, so it can be set from whatever deadline a
deployment or orchestrator imposes. Anything still running when it expires is
abandoned and redelivered after its visibility timeout.

> [!WARNING]
> Make sure your orchestrator's grace period exceeds `:drain_timeout`.
> Kubernetes defaults `terminationGracePeriodSeconds` to 30 and this defaults
> to 30 seconds — a dead heat, where `SIGKILL` can land exactly as the final
> acknowledgements are being flushed.

### Signals

There is nothing to wire up. A release shuts down on `SIGTERM`, which stops
your application, which stops the worker, which drains. `docker stop`,
`systemctl stop` and Kubernetes pod termination all send `SIGTERM`.

`SIGINT` is a different matter: the BEAM reserves it for its break handler, so
`Ctrl-C` in `iex` does **not** drain. Use `System.stop()` in development when
you want a clean shutdown.

Stopping one worker without stopping the application works as you would
expect:

> Elixir:
>
> ```elixir
> Supervisor.stop(MyApp.EmailWorker)
> ```

## Observing a worker

Workers emit `:telemetry` events for every job — start, stop and exception —
carrying the worker's name, the job's id, type and queue, and the outcome. See
[Telemetry](./telemetry.md) for the full list, and attach whatever your
monitoring stack expects.
