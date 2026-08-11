# Changelog

## 0.6.0-alpha.5

Adds the declarative layer: jobs as modules, dispatch by type, and
keys derived from the payload for uniqueness and batching. The query
and cron endpoints are still to come.

### Added

- **`Zizq.JobKind`.** Declares a kind of job — its name on the server,
  the enqueue options it defaults to, and what running it does:

      defmodule MyApp.SendEmail do
        use Zizq.JobKind, type: "send_email", queue: "emails"

        @impl Zizq.JobKind
        def perform(%{"user_id" => id}), do: MyApp.Mailer.deliver(id)
      end

      MyApp.SendEmail.new(%{"user_id" => 42})
      |> Zizq.enqueue(MyApp.Zizq)

  `type:` is required and never inferred from the module name, so
  renaming the module cannot silently change the wire contract other
  languages enqueue against. Everything else is any option
  `Zizq.Enqueue` takes, validated while the module compiles, so a
  malformed `:backoff` is a build failure rather than a surprise at
  the first enqueue.

  Define `perform/1`, or `perform/2` to also receive the `Zizq.Job`.
  Defining both prefers `/2`; defining neither fails at compile time.
  The choice is resolved during compilation, so dispatch costs nothing
  at runtime.

- **`Zizq.Router`.** Dispatches jobs to the module that defines them,
  and is accepted directly as a worker's `:handler`:

      {Zizq.Worker,
       client: MyApp.Zizq,
       queues: ["emails"],
       handler: Zizq.Router.new([MyApp.SendEmail, MyApp.GenerateReport])}

  Routes can also be added one at a time, which suits building them
  conditionally, and plain functions can be registered for jobs not
  worth a module:

      Zizq.Router.new()
      |> Zizq.Router.route(MyApp.SendEmail)
      |> Zizq.Router.route("ping", fn _payload -> :ok end)
      |> Zizq.Router.fallback(&MyApp.unknown_job/1)

  A type in no route raises `Zizq.Router.UnknownJobType`, which the
  worker reports as a failure, so the job retries — usually right,
  since a rolling deploy can enqueue from new code onto a worker
  running old code. A `:fallback` handles them instead.

  Types are registered, never resolved: turning a wire type into a
  module at runtime would mean `String.to_existing_atom/1` on data
  from the queue.

- **Unique keys derived from the payload.** Deduplicate on the fields
  that decide identity, ignoring the ones that do not:

      use Zizq.JobKind,
        type: "send_email",
        unique_key: {:payload, only: [".user_id", ".template"]},
        unique_while: :queued

  `{:payload, except: [...]}` and `:payload` (the whole payload) are
  the other forms, and all three work on a plain `Zizq.enqueue/2` as
  well. Paths are jq-flavoured, and are parsed while the job module
  compiles, so a malformed one is a build failure and no enqueue pays
  to parse it.

  `Zizq.PayloadHasher` builds the keys, hashing canonical JSON into
  SHA-256 so that key order does not matter but structure does. Keys
  are prefixed with the job type by default, since two kinds of job
  with identical payloads are still different jobs.

- **Batch configuration generated from a path and a limit.** Say where
  the batch accumulates and how large it may get; the jq expressions
  follow:

      use Zizq.JobKind,
        type: "push",
        batch: [limit: 100, path: ".device_ids"]

  The key defaults to hashing everything *except* the batch path, so
  enqueues alike in every respect but what they contribute belong to
  the same batch — no key needs naming. `:dedup` and `:sorted` fold
  through jq's `unique` and `sort`. `:key`, `:when` and `:fold` can
  still be written by hand for folds the template does not cover.

### Fixed

- **An enqueue that matched an existing job crashed instead of
  returning it.** The server answers 200 rather than 201 when nothing
  new was created — a unique job already queued, or one folded into a
  batch — and `Zizq.enqueue/2` treated only 201 as success. The 200
  fell through to the error path, where the status mapping had no
  clause for it and raised `FunctionClauseError`. Both statuses are
  now success, and the returned job carries `:duplicate` or `:folded`.
  `Zizq.enqueue_all/2` was already correct.

- **An unrecognised status now arrives as an error rather than a
  crash.** `Zizq.Error` gains an `:unexpected_status` reason, so a
  status an endpoint does not know how to read still surfaces as a
  `%Zizq.Error{}` naming it, which is the whole point of there being
  one error type.

## 0.6.0-alpha.4

Adds job consumption: a supervised worker, the `/jobs/take` stream and
the acknowledgement endpoints underneath it. The query and cron
endpoints are still to come.

### Added

- **`Zizq.Worker`.** Takes jobs from one or more queues and runs them.
  Add one to your supervision tree alongside a client:

      children = [
        {Zizq, name: MyApp.Zizq, url: "http://localhost:7890"},
        {Zizq.Worker,
         client: MyApp.Zizq,
         queues: ["emails"],
         concurrency: 25,
         handler: &MyApp.handle_job/1}
      ]

  The order matters: children are stopped in reverse, so the worker
  drains while the client it acknowledges through is still alive.

  Each job runs in its own supervised task. A handler that raises,
  exits or is killed outright is reported to the server as a failure
  with its exception and stacktrace, and cannot take the worker down;
  a slow one cannot block the stream from being read. What a handler
  returns decides the job's fate — `:ok` or `{:ok, term}` completes
  it, `{:error, reason}` fails it for retry under the backoff policy,
  `{:cancel, reason}` kills it whatever attempts remain, and
  `{:snooze, milliseconds}` or `{:snooze, %DateTime{}}` defers it.
  Anything else is acknowledged as complete and logged as a warning
  naming what came back, since a handler that ended on the wrong value
  has most likely already done its work.

  **Snooze durations are milliseconds**, as every duration in this
  client is.

  On shutdown the worker stops taking new work, lets running jobs
  finish, flushes outstanding acknowledgements, and only then closes
  the connection — in that order, so the server keeps the in-flight
  jobs until the acknowledgements arrive. `:drain_timeout` (30s by
  default) is the whole budget rather than a per-step one, so it can be
  set from whatever deadline a deployment or orchestrator imposes;
  anything still running when it expires is abandoned and redelivered.

- **`Zizq.report_success/2`, `Zizq.report_success_all/2` and
  `Zizq.report_failure/3`.** Acknowledge jobs directly, for consumers
  not built on `Zizq.Worker`. `report_failure/3` takes `:message`
  (required), `:error_type`, `:backtrace`, `:kill` to declare a job
  dead now, and `:retry_at` to reschedule it bypassing the backoff
  policy.

- **`:stream_idle_timeout` client option**, 30s by default. How long a
  streaming connection may go without any data before it is treated as
  dead and reconnected. The server heartbeats every three seconds by
  default, so raise this if yours is configured to heartbeat less
  often.

## 0.6.0-alpha.3

Adds bulk enqueue. Consuming jobs is still to come, as are the query
and cron endpoints.

### Changed

- **Breaking: `enqueue/2`, `enqueue!/2`, `enqueue_all/2` and
  `enqueue_all!/2` now take the job first and the client second.**

      # before
      Zizq.enqueue(MyApp.Zizq, type: "send_email")

      # now
      Zizq.Enqueue.new!(type: "send_email") |> Zizq.enqueue(MyApp.Zizq)

  `|>` passes its left-hand value as the first argument, so the old
  order could not be piped without wrapping every call in `then/2`.
  Elixir's convention is that the subject comes first, and here the
  subject is the job — which matters more once job modules are
  building enqueues and pipelines become the normal way to write them.

- **`:unique_key` and `:batch` together are now rejected locally.** The
  server refuses the combination on both endpoints; catching it in
  `Zizq.Enqueue` turns a round trip into an immediate error at the call
  site that got it wrong.

### Added

- **`Zizq.enqueue_all/2` and `Zizq.enqueue_all!/2`.** Enqueue many jobs
  in a single request:

      users
      |> Enum.map(&Zizq.Enqueue.new!(type: "send_email", payload: %{"user_id" => &1.id}))
      |> Zizq.enqueue_all(MyApp.Zizq)

  Elements may be `Zizq.Enqueue` structs, keyword lists or maps, mixed
  freely. Jobs are returned in the order they were sent, and an empty
  list short-circuits immediately without contacting the server.

## 0.6.0-alpha.2

First release with a usable API. Jobs can be enqueued; consuming them
cannot — the take stream and worker are still to come, as are the
query, cron and bulk endpoints.

### Added

- **`Zizq` client supervisor.** Add one to your application's
  supervision tree and refer to it by name:

      children = [
        {Zizq, name: MyApp.Zizq, url: "http://localhost:7890"}
      ]

  Several named clients can run side by side. API functions are
  stateless — they resolve configuration by name and issue the request
  directly, so no Zizq process sits in the request path. Options are
  validated at startup, so a malformed URL or unknown format fails at
  boot rather than on the first request.

- **`Zizq.enqueue/2` and `Zizq.enqueue!/2`.** Accepts a keyword list,
  a map, or a `Zizq.Enqueue` struct. Only `:type` is required;
  `:queue` defaults to `"default"`, and anything left unset is omitted
  from the request so the server's own defaults apply and keep
  tracking its configuration. Unknown keys are rejected rather than
  ignored, so a typo cannot quietly enqueue the wrong job.

- **`Zizq.Job`.** The job record the server returns. Timestamps are
  `DateTime` in UTC; status is an atom (`:ready`, `:in_flight`, and so
  on). A status an older client does not recognise is preserved as a
  string rather than raising.

- **`Zizq.Backoff`, `Zizq.Retention`, `Zizq.BatchConfig`.** Per-job
  policy overrides, accepted as keyword lists or structs. Durations
  are integer milliseconds throughout, so `:timer.seconds/1` and
  friends can be used directly.

- **`Zizq.Codec` behaviour, with `Zizq.Codec.JSON` and
  `Zizq.Codec.MessagePack`.** MessagePack is the default. The two are
  interchangeable on every endpoint, so a producer and a consumer need
  not agree on a format, or even be written in the same language.
  Select with `format: :json`.

- **`Zizq.Error`.** One error type for every failure, carrying a
  `:reason` atom, the HTTP status and body where there was one, and
  the underlying exception behind transport and codec failures.
  `Zizq.Error.retryable?/1` says whether retrying could plausibly
  succeed.

- **`Zizq.server_version/1`.** Reports the server's version; the
  cheapest way to confirm a connection works end to end.

### Notes

- Request and response traffic uses HTTP/2 over cleartext (h2c) with
  connection multiplexing. The forthcoming take stream will use
  HTTP/1.1 instead, where HTTP/2 framing overhead makes it slower.
- Requires Elixir 1.18 or later and Erlang/OTP 27 or later.
- Pre-release versions are opt-in: a requirement must name one (for
  example `~> 0.6.0-alpha`) to resolve them.

## 0.6.0-alpha.1

Package skeleton only. No client API yet. Published purely to exercise
the release pipeline.
