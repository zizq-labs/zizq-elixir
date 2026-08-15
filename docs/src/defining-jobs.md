# Defining Jobs

A job has two halves: a **type** that identifies it on the server, and a
**handler** that runs when one arrives at the worker. `Zizq.JobKind` declares
both in one module, along with any defaults that job should be enqueued with.

Job modules are optional. A plain keyword list enqueues perfectly well, and
[Enqueuing Jobs](./enqueuing-jobs.md) shows that form. A module is worth it
once a job has defaults worth stating once rather than at every call site, and
when your job is owned end-to-end by your application.

## Declaring a job

> Elixir:
>
> ```elixir
> defmodule MyApp.SendEmail do
>   use Zizq.JobKind, type: "send_email", queue: "emails"
>
>   @impl Zizq.JobKind
>   def perform(%{"user_id" => user_id, "template" => template}) do
>     MyApp.Mailer.deliver(user_id, template)
>   end
> end
> ```

That gives the module three functions:

- `type/0` — the job's name on the server, `"send_email"` here.
- `new/1` and `new/2` — build an enqueue, without sending it.
- the `perform` you wrote, wired up so a worker can call it.

Enqueue it with:

> Elixir:
>
> ```elixir
> MyApp.SendEmail.new(%{"user_id" => 42, "template" => "welcome"})
> |> Zizq.enqueue(MyApp.Zizq)
> ```

## The job type name

`:type` is the only required option, and it is **never inferred from the
module name**.

Elixir module names cannot serve as wire types: `MyApp.SendEmail` is really
the atom `Elixir.MyApp.SendEmail`, which is neither portable nor pleasant for
a producer written in another language. Deriving something friendlier from it
would tie a cross-language contract to an Elixir refactor — renaming the
module to `MyApp.SendEmailJob` would silently change the type, orphaning every
queued job and every producer that enqueues it, with no compile error to say
so.

So the type is statically defined, and renaming the module changes nothing:

> Elixir:
>
> ```elixir
> use Zizq.JobKind, type: "send_email"
> ```

> [!TIP]
> Types are strings shared across languages. A job enqueued here as
> `"send_email"` can be run by a Ruby, Node or Rust worker that registers the
> same name, and vice versa.

## Per-type defaults

Any option [`Zizq.Enqueue`](./enqueuing-jobs.md) accepts can be given a
default here, so every enqueue of this job starts from it:

> Elixir:
>
> ```elixir
> defmodule MyApp.SendEmail do
>   use Zizq.JobKind,
>     type: "send_email",
>     queue: "emails",
>     priority: 100,
>     retry_limit: 5,
>     backoff: [base: :timer.seconds(15), exponent: 4.0, jitter: :timer.seconds(30)],
>     retention: [completed: :timer.hours(24), dead: :timer.hours(24 * 7)]
>
>   @impl Zizq.JobKind
>   def perform(payload), do: MyApp.Mailer.deliver(payload)
> end
> ```

Options are validated **while the module compiles**, so a malformed policy is
a build failure rather than a surprise at the first enqueue:

> Command:
>
> ```bash
> $ mix compile
> ** (ArgumentError) backoff :base must be a non-negative integer, got "soon"
> ```

### Queue

`:queue` decides which queue the job is placed on. It defaults to `"default"`
in the client — the server has no default of its own, so every enqueue must
carry one.

> Elixir:
>
> ```elixir
> use Zizq.JobKind, type: "send_email", queue: "emails"
> ```

### Priority

Lower runs sooner. Jobs of equal priority run oldest-first.

> Elixir:
>
> ```elixir
> use Zizq.JobKind, type: "send_email", priority: 10
> ```

### Retry limit

How many attempts a job gets before it is declared dead.

> Elixir:
>
> ```elixir
> use Zizq.JobKind, type: "send_email", retry_limit: 5
> ```

### Backoff policy

How long the server waits before retrying a failed job. The delay is:

```
delay = base + (attempts ** exponent) * 1000 + attempts * rand(0..jitter)
```

`:base` and `:jitter` are milliseconds; `:exponent` is dimensionless. All
three are required together — the server has no partial defaults.

> Elixir:
>
> ```elixir
> use Zizq.JobKind,
>   type: "send_email",
>   backoff: [base: :timer.seconds(15), exponent: 4.0, jitter: :timer.seconds(30)]
> ```

The `:jitter` term is multiplied by the attempt count, so retries spread
further apart as they accumulate. That matters when a downstream service
falls over and a thousand jobs fail at once: without jitter they would all
retry in the same instant, repeatedly.

### Retention policy

How long a job stays on the server after finishing, so it can still be read
back. Both values are milliseconds and both are optional.

> Elixir:
>
> ```elixir
> use Zizq.JobKind,
>   type: "send_email",
>   retention: [completed: :timer.hours(24), dead: :timer.hours(24 * 7)]
> ```

> [!NOTE]
> The server's default retention for **completed** jobs is zero — a job that
> succeeds is purged immediately. If you want to look one up afterwards, or
> assert on it in a test, set `:completed` explicitly.

### Uniqueness and batching

`:unique_key` and `:unique_while` deduplicate jobs at enqueue time, and
`:batch` folds many enqueues into one job. Both are declared here:

> Elixir:
>
> ```elixir
> use Zizq.JobKind,
>   type: "send_email",
>   unique_key: {:payload, only: [".user_id", ".template"]},
>   unique_while: :queued
> ```

They both have dedicated docs — see [Unique Jobs](./unique-jobs.md) and
[Batched Jobs](./batched-jobs.md). Both require a Pro-license on the server.

### Omitted options track the server

An option you do not set is **left out of the request entirely**, rather than
being sent as a client-side default. The server then applies its own, which
means reconfiguring a server default affects jobs already being enqueued,
instead of every application having to redeploy.

That is why there is no `retry_limit: 25` sitting in this client as a
fallback. If you want the server's value, say nothing.

## Handlers

`perform/1` receives the payload. `perform/2` receives the payload and the
`Zizq.Job` it came from, for when the attempt count, id or queue matters:

> Elixir:
>
> ```elixir
> defmodule MyApp.SendEmail do
>   use Zizq.JobKind, type: "send_email"
>
>   @impl Zizq.JobKind
>   def perform(payload, %Zizq.Job{attempts: attempts}) when attempts >= 3 do
>     MyApp.Mailer.deliver_without_retry(payload)
>   end
>
>   def perform(payload, _job) do
>     MyApp.Mailer.deliver(payload)
>   end
> end
> ```

Define whichever arity you need. Defining both is fine and `perform/2` wins —
a `/1` convenience wrapper alongside is ordinary Elixir, not a mistake.
Defining neither fails at compile time:

> Command:
>
> ```bash
> $ mix compile
> ** (CompileError) MyApp.SendEmail uses Zizq.JobKind but defines neither
>    perform/1 nor perform/2
> ```

The choice is resolved while the module compiles, so dispatching to the right
arity costs nothing at runtime.

> [!NOTE]
> `:attempts` counts attempts that have already **finished**, so it is `0`
> while a job runs for the first time — the guard above first matches on the
> fourth run.

### Payloads are string-keyed

Whatever you enqueue goes out as JSON or MessagePack, so a handler always
receives string keys:

> Elixir:
>
> ```elixir
> # Enqueued with atom keys …
> MyApp.SendEmail.new(%{user_id: 42})
>
> # … arrives with string keys.
> def perform(%{"user_id" => user_id}), do: ...
> ```

Match on string keys and your handler behaves the same in tests as in
production. This is a guarantee, not an accident: both codecs hand back
string-keyed maps, so a job enqueued as MessagePack and read as JSON looks
identical to the handler.

### What perform returns

The return value decides what happens to the job:

Returns | Outcome
--- | ---
`:ok` or `{:ok, term}` | acknowledged as complete
`{:error, reason}` | failed; retried per the backoff policy
`{:cancel, reason}` | killed now, whatever retries remain
`{:snooze, milliseconds}` | retried after that long, ignoring backoff
`{:snooze, %DateTime{}}` | retried at that time, ignoring backoff
raises, exits, or is killed | failed, with the exception and stacktrace

> Elixir:
>
> ```elixir
> @impl Zizq.JobKind
> def perform(payload) do
>   case MyApp.Billing.charge(payload) do
>     :ok                         -> :ok
>     {:error, :rate_limited}     -> {:snooze, :timer.minutes(5)}
>     {:error, :customer_deleted} -> {:cancel, :gone}
>     {:error, reason}            -> {:error, reason}
>   end
> end
> ```

> [!WARNING]
> Snooze durations are **milliseconds**, as every duration in this client is.
> Oban's equivalent is in seconds, so a handler ported across unchanged would
> retry a thousand times sooner than intended — and nothing would raise.

Anything else is acknowledged as complete and logged as a warning naming what
came back. Failing the job instead would be worse: a handler that ended on the
wrong value has most likely already done its work, so failing it would repeat
a side effect that already happened. But completing it silently would bury a
real mistake — `:error` where `{:error, reason}` was meant — under a queue
that looks perfectly healthy.

## Building an enqueue

`new/1` builds a `Zizq.Enqueue` and sends nothing, so enqueues compose:

> Elixir:
>
> ```elixir
> # One job.
> MyApp.SendEmail.new(%{"user_id" => 42}) |> Zizq.enqueue(MyApp.Zizq)
>
> # Many in one request.
> users
> |> Enum.map(&MyApp.SendEmail.new(%{"user_id" => &1.id}))
> |> Zizq.enqueue_all(MyApp.Zizq)
> ```

`new/2` takes per-enqueue overrides on top of the module's defaults, covered
in [Enqueuing Jobs](./enqueuing-jobs.md).

## Producing without consuming

A job module is worth defining where the job is **run**. An application that
only enqueues work handled elsewhere — by another service, or another
language — has no `perform` to write, and should build enqueues directly:

> Elixir:
>
> ```elixir
> Zizq.enqueue(
>   [type: "send_email", queue: "emails", payload: %{"user_id" => 42}],
>   MyApp.Zizq
> )
> ```

That is the whole API for a producer. Nothing about enqueuing requires a
module.
