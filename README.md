# Zizq Elixir Client

Official Elixir client for the [Zizq](https://zizq.io) job queue server.

Zizq is a fast and durable job queue built on an embedded LSM database —
not on Redis, and not on your RDBMS. It supports multiple producers and
multiple consumers across an entire stack, with producers and consumers
written in any language.

[![CI](https://github.com/zizq-labs/zizq-elixir/actions/workflows/ci.yml/badge.svg)](https://github.com/zizq-labs/zizq-elixir/actions/workflows/ci.yml)

> **Work in progress.** This client is under active development and does
> not yet implement the API. It is made available on GitHub for
> visibility and feedback.

## Installation

Add `zizq` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:zizq, "~> 0.6.0-alpha"}
  ]
end
```

The `-alpha` in the requirement is currently required: releases
during development are pre-releases, and Hex excludes those from
ordinary requirements. A plain `~> 0.6.0` will not resolve them.

Requires Elixir 1.18 or later (for the built-in `JSON` module) and
Erlang/OTP 27 or later.

## Sneak peek

None of this works yet, but this is the API being built towards, and
every detail is subject to change as development progresses. The
examples are here purely for transparency and early feedback.

### Setup

Add a client to your supervision tree. Producers need only this:

```elixir
children = [
  {Zizq, name: MyApp.Zizq, url: "http://localhost:7890", format: :msgpack}
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

`perform/2` is also available when a job needs the metadata — the
attempt count, the job id, the queue it came from:

```elixir
@impl Zizq.JobKind
def perform(payload, %Zizq.Job{attempts: attempts}) when attempts >= 3 do
  MyApp.Mailer.deliver_without_retry(payload)
end

def perform(payload, _job) do
  MyApp.Mailer.deliver(payload)
end
```

Define whichever arity you need; the macro wires up the one you defined
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
in-flight jobs, flushes pending acknowledgements, and only then closes
the connection.

### Routing

The worker's only dispatch interface is `handler:`. Anything that takes
a `%Zizq.Job{}` — the server's job record, as distinct from the
`Zizq.JobKind` behaviour used to declare one — and succeeds or fails.
`Zizq.Router` is a builder for one, and job types are plain strings:

```elixir
Zizq.Router.new()
|> Zizq.Router.route("send_email", &MyApp.Mailer.send/1)
|> Zizq.Router.route("charge_card", fn payload, job -> ... end)
|> Zizq.Router.fallback(&MyApp.unknown_job/1)
```

Routes take the payload, or the payload and the job, as you prefer. A
plain function works too (e.g. `handler: &MyApp.dispatch/1`) if you
would rather write the dispatch yourself. Middleware is then just
function composition; there is no separate concept for it.

### Job outcomes

The return value of `perform/2` decides what happens next:

```elixir
def perform(payload, _job) do
  case MyApp.Billing.charge(payload) do
    :ok                         -> :ok               # acknowledge
    {:error, :rate_limited}     -> {:snooze, 60}     # retry in 60 seconds
    {:error, :customer_deleted} -> {:cancel, :gone}  # kill, do not retry
    {:error, reason}            -> {:error, reason}  # retry with backoff
  end
end
```

Raising, exiting or crashing is equivalent to `{:error, _}`, with the
exception and stacktrace reported to the server.

### Without the macro

Zizq is a polyglot queue. Jobs enqueued here may be processed by a
worker written in Ruby, Node or Rust, and vice versa. The macro layer is
sugar over a plain functional API that takes maps with string keys:

```elixir
Zizq.enqueue(MyApp.Zizq, %{
  type: "send_email",
  queue: "emails",
  payload: %{"user_id" => 42, "template" => "welcome"}
})
```

## Versioning

Client versions track the server's `MAJOR.MINOR`; the `PATCH` component
moves independently. A `0.6.x` client works with a `0.6.x` server or
later. A `0.6.x` client is not supported with servers `< 0.6.x`.

Until this client is feature-complete it will be published as
`0.6.0-alpha.N` pre-releases. Pre-releases are opt-in — only a
requirement that itself names a pre-release (such as `~> 0.6.0-alpha`)
will resolve one — so the eventual `0.6.0` is the first version an
ordinary `~> 0.6.0` will pick up.

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

To run the integration suite against a real server binary:

```bash
./integration/run.sh \
  --binary /path/to/zizq \
  --tarball _build/release/zizq-<version>.tar
```

## Resources

* [Elixir Client Docs](https://zizq.io/docs/clients/elixir/) — Coming soon
* [Elixir Client API reference](https://hexdocs.pm/zizq) — Coming soon
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
