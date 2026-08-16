# Zizq Elixir Client

Official Elixir client for the [Zizq](https://zizq.io) job queue server.

Zizq (**/zɪsk/**) is a fast and durable job queue built on an embedded LSM
database — not on Redis, and not on your RDBMS. It supports multiple
producers and multiple consumers across an entire stack, with producers
and consumers written in any language.

[![CI](https://github.com/zizq-labs/zizq-elixir/actions/workflows/ci.yml/badge.svg)](https://github.com/zizq-labs/zizq-elixir/actions/workflows/ci.yml)

## Installation

Add `zizq` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:zizq, "~> 0.6.0"}
  ]
end
```

Requires Elixir 1.18 or later (for the built-in `JSON` module) and
Erlang/OTP 27 or later.

## Usage

### Setup

Add a client to your supervision tree. Producers need only this:

```elixir
children = [
  {Zizq, name: MyApp.Zizq, url: "http://localhost:7890"}
]
```

### Defining a job

```elixir
defmodule MyApp.SendEmail do
  use Zizq.JobKind,
    type: "send_email",
    queue: "emails",
    priority: 100,
    retry_limit: 5,
    backoff: [base: :timer.seconds(15), exponent: 4.0, jitter: :timer.seconds(30)],
    retention: [completed: :timer.hours(24), dead: :timer.hours(24 * 7)],
    unique_key: {:payload, only: [".user_id", ".template"]},
    unique_while: :queued

  @impl Zizq.JobKind
  def perform(%{"user_id" => user_id, "template" => template}) do
    MyApp.Mailer.deliver(user_id, template)
  end
end
```

`type:` is the job's name on the Zizq server, which is the `"type"`
field other languages would also see, and what they enqueue to reach
this handler. It is required and never inferred from the module name,
so renaming `MyApp.SendEmail` cannot silently break in-flight jobs or
a producer written in another language.

It is also the *only* required option. Everything above it is optional,
so the smallest useful job is:

```elixir
defmodule MyApp.GenerateReport do
  use Zizq.JobKind, type: "generate_report"

  @impl Zizq.JobKind
  def perform(%{"report_id" => id}), do: MyApp.Reports.generate(id)
end
```

`queue:` defaults to `"default"` on the client. Other options have
server-side defaults.

> [!NOTE]
> **Durations are in milliseconds**. `:timer.seconds/1`, `:timer.minutes/1`
> and `:timer.hours/1` keep call sites readable and are evaluated at
> compile time.

`perform/2` is also available when a job needs the metadata such as the
attempt count, the job id, the queue it came from, etc:

```elixir
@impl Zizq.JobKind
def perform(payload, %Zizq.Job{attempts: attempts}) when attempts >= 3 do
  MyApp.Mailer.deliver_without_retry(payload)
end

def perform(payload, _job) do
  MyApp.Mailer.deliver(payload)
end
```

Define whichever arity you need. The macro wires up the one you defined
and raises at compile time if you define neither.

### Enqueuing

`new/2` builds a plain struct and sends nothing, so enqueues compose:

```elixir
# Enqueue one job.
MyApp.SendEmail.new(%{user_id: 42, template: "welcome"})
|> Zizq.enqueue(MyApp.Zizq)
#=> {:ok, %Zizq.Job{id: "01K9…", queue: "emails", status: :ready}}

# Per-enqueue overrides on top of the module's defaults.
MyApp.SendEmail.new(%{user_id: 42}, priority: 10, ready_at: ~U[2026-08-08 09:00:00Z])
|> Zizq.enqueue(MyApp.Zizq)

# Enqueue many in one request.
users
|> Enum.map(&MyApp.SendEmail.new(%{user_id: &1.id}))
|> Zizq.enqueue_all(MyApp.Zizq)
```

### Running a worker

```elixir
children = [
  {Zizq, name: MyApp.Zizq, url: "http://localhost:7890"},
  {Zizq.Worker,
   client: MyApp.Zizq,
   queues: ["emails", "reports"],
   concurrency: 25,
   handler: Zizq.Router.new([MyApp.SendEmail, MyApp.GenerateReport])}
]
```

Each job runs in its own supervised task, so a crashing job cannot take
the worker down. On shutdown the worker stops taking new work, waits for
in-flight jobs, flushes pending acknowledgements, and then disconnects.

### Routing

The worker's only dispatch interface is `handler:`. Anything that takes
a `%Zizq.Job{}` (the server's job record) and succeeds or fails.
A `Zizq.Router` is accepted too, and dispatches by job type. Job types
are plain strings:

```elixir
Zizq.Router.new()
|> Zizq.Router.route("send_email", &MyApp.Mailer.send/1)
|> Zizq.Router.route("charge_card", fn payload, job -> ... end)
|> Zizq.Router.fallback(&MyApp.unknown_job/1)
```

Routes take the payload, or optionally the payload and the job. A
plain function works too (e.g. `handler: &MyApp.dispatch/1`) if you
would rather write the dispatch yourself. Middleware is then just
normal function composition; there is no separate concept for it.

### Job outcomes

The return value of `perform/2` drives what happens to the job next:

```elixir
def perform(payload, _job) do
  case MyApp.Billing.charge(payload) do
    :ok                         -> :ok               # acknowledge
    {:error, :rate_limited}     -> {:snooze, 60_000} # retry in a minute
    {:error, :customer_deleted} -> {:cancel, :gone}  # kill, do not retry
    {:error, reason}            -> {:error, reason}  # retry with backoff
  end
end
```

Raising, exiting or crashing is equivalent to `{:error, _}`, with the
exception and stacktrace reported to the server.

### Finding and changing jobs

One job at a time:

```elixir
{:ok, job} = Zizq.get_job(id, MyApp.Zizq)

Zizq.update_job(job, MyApp.Zizq, queue: "urgent", priority: 0)
Zizq.delete_job(job, MyApp.Zizq)
```

Updates are a merge patch: an option left out leaves that field alone,
and `nil` clears it back to the server's default.

The Zizq Elixir client also includes `Zizq.Query` for composable streaming
queries and updates.

Many at a time with a query, which pages as it goes:

```elixir
Zizq.query(MyApp.Zizq)
|> Zizq.Query.where(queue: "emails", status: [:ready])
|> Enum.take(10)
```

A query is enumerable, so `Enum` and `Stream` work on it and only the
pages actually needed are fetched. The example above stops after the
first. `Enum.count/1` asks the server to count rather than walking
pages.

Filters are the same everywhere: `:id`, `:queue`, `:type`, `:status`,
`:priority`, `:ready_at`, `:attempts`, and `:filter` for a jq
expression over the payload. Ranges take a number, a `Range`, or
`[min: _, max: _]`.

Acting on everything a query matches is one request:

```elixir
Zizq.query(MyApp.Zizq)
|> Zizq.Query.where(queue: "emails", status: :dead)
|> Zizq.Query.delete_all()
```

Add `Zizq.Query.in_pages_of/2` and it works a page at a time instead,
which turns what would be one enormous atomic transaction into a series
of smaller commits.

When a job fails, the server keeps a record per attempt:

```elixir
{:ok, page} = Zizq.list_errors(job, MyApp.Zizq)
```

### Scheduled jobs

A cron schedule is a named group of entries, installed as a whole.
Doing this on every boot converges rather than accumulates, so every
instance of an application can run it without coordinating:

```elixir
Zizq.Cron.new("my_app",
  entries: [
    [name: "nightly_cleanup",
     expression: "0 3 * * *",
     job: MyApp.Cleanup.new(%{})],
    [name: "digest",
     expression: "*/15 * * * *",
     timezone: "Australia/Melbourne",
     job: [type: "digest", queue: "reports"]]
  ]
)
|> Zizq.replace_cron(MyApp.Zizq)
```

Or constructed with the pipeline operator:

```elixir
Zizq.Cron.new("my_app")
|> Zizq.Cron.put_entry(
  name: "nightly_cleanup",
  expression: "0 3 * * *",
  job: MyApp.Cleanup.new(%{})
)
|> Zizq.Cron.put_entry(
  name: "digest",
  expression: "*/15 * * * *",
  timezone: "Australia/Melbourne",
  job: [type: "digest", queue: "reports"]
)
|> Zizq.replace_cron(MyApp.Zizq)
```

Entries left out are removed, so what you pass is the whole schedule
rather than just an addition to it. An entry's job is an ordinary
enqueue, so anything you can enqueue normally you can schedule (with
the exception of scheduled jobs with a hard-coded `:ready_at`).

There is also `Zizq.get_cron/2`, `Zizq.list_crons/1`,
`Zizq.delete_cron/2`, and `Zizq.pause_cron/2` / `Zizq.resume_cron/2`
for the whole group or `Zizq.pause_cron_entry/2` for one entry.

### Testing

Assert on what your code enqueued, without a server:

```elixir
defmodule MyApp.SignupTest do
  use ExUnit.Case, async: true
  use Zizq.Testing, client: MyApp.Zizq

  test "signing up sends a welcome email" do
    MyApp.Signup.run("ada@example.com")

    assert_enqueued(type: "send_email", payload: %{"template" => "welcome"})
  end
end
```

Recordings belong to the test that made them, so a fixed client name is
safe under `async: true`. `perform_job/3` runs one handler directly and
`drain_enqueued/2` runs everything that was enqueued.

### Telemetry

Jobs, enqueues and the take stream emit `:telemetry` events, so
AppSignal, Sentry, Datadog, OpenTelemetry, etc and `Telemetry.Metrics`
work without any glue:

```elixir
:telemetry.attach_many(
  "zizq",
  [[:zizq, :job, :stop], [:zizq, :job, :exception]],
  &MyApp.Telemetry.handle/4,
  nil
)
```

See `Zizq.Telemetry` for every event and its metadata.

### Without the macro

Zizq is a polyglot queue. Jobs enqueued here may be processed by a
worker written in Ruby, Node or Rust, and vice versa. The macro layer is
sugar over a plain functional API that takes a keyword list or map:

```elixir
Zizq.enqueue(
  %{
    type: "send_email",
    queue: "emails",
    payload: %{"user_id" => 42, "template" => "welcome"}
  },
  MyApp.Zizq
)
```

## Versioning

Client versions track the server's `MAJOR.MINOR`; the `PATCH` component
moves independently. A `0.6.x` client works with a `0.6.x` server or
later. A `0.6.x` client is not supported with servers `< 0.6.x`. The
`MAJOR` must always match.

## Development

```bash
mix deps.get
mix test
mix format --check-formatted
```

To build the Hex package locally:

```bash
./release.sh
```

To run the integration suite against a compatible server binary:

```bash
./integration/run.sh --binary /path/to/zizq
```

It builds the package from source unless `--tarball` names one. Cron,
unique keys and batching need a licensed server, and are skipped
without one; pass `--license-key "@/path/to/licence.jwt"` to include
them.

## Resources

* [Elixir Client Docs](https://zizq.io/docs/clients/elixir/)
* [Elixir Client API reference](https://hexdocs.pm/zizq)
* [Getting Started Docs](https://zizq.io/docs/getting-started/)
* [Zizq Command Reference](https://zizq.io/docs/cli/)
* [Elixir Client Source](https://github.com/zizq-labs/zizq-elixir)
* [Zizq Source](https://github.com/zizq-labs/zizq)

## Support & Feedback

If you need help using Zizq,
[create an issue](https://github.com/zizq-labs/zizq-elixir/issues) on the
[zizq-elixir](https://github.com/zizq-labs/zizq-elixir) repo. Feedback is very
welcome.

## License

MIT — see [LICENSE](LICENSE).
