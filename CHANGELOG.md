# Changelog

## 0.6.0-alpha.9

### Added

- **`Zizq.Testing.clear_enqueued/0`.** Forgets what a test has
  recorded so far, so a test that acts twice can assert on the second
  action alone:

      MyApp.Sitemap.scan(sitemap)
      assert_enqueued(type: "check_url")

      clear_enqueued()

      # The second scan should find nothing new to do.
      MyApp.Sitemap.scan(sitemap)
      refute_enqueued(type: "check_url")

  Without it a refutation cannot tell the two actions apart, since the
  first one's enqueues are still recorded. Clearing is scoped to the
  test that calls it, so it stays safe under `async: true`.

  Found while writing the `uptime_monitor` example, where a sitemap is
  rescanned and the second pass should enqueue nothing new.

## 0.6.0-alpha.8

Adds a composable query over the listing endpoints, so paging is
something the client does rather than something you write.

### Added

- **`Zizq.query/1` and `Zizq.Query`.** A query is enumerable, so
  `Enum` and `Stream` work on it directly and pages are fetched only
  as they are needed:

      Zizq.query(MyApp.Zizq)
      |> Zizq.Query.where(queue: "emails", status: [:ready])
      |> Enum.take(10)

  That stops after the first page or two, because `Enum.take/2` stops
  asking. Run to completion, the same query walks every page. Building
  one sends nothing; a request happens when it is enumerated, counted,
  or acted on.

  `where/2` takes the filters `Zizq.Filter` already documents and can
  be called repeatedly, later calls winning per key — one function
  rather than a `by_queue`, `by_status` and so on for each field,
  since the filters are already a keyword list. It validates as the
  query is built, so a typo fails at the line that made it rather than
  wherever the query is eventually run.

  `order/2` picks the direction, `limit/2` caps the total, and
  `in_pages_of/2` sets how many are fetched per request — the last two
  are independent, being *what you want* and *how eagerly it is
  fetched*.

  `Enum.count/1` asks the server to count rather than walking pages,
  so it costs one request whatever the total, and agrees with what
  enumerating the same query yields.

  `pages/1` streams whole `Zizq.JobPage`s for when a page is the
  useful unit.

- **Acting on everything a query matches.** `Zizq.Query.update_all/2`
  and `Zizq.Query.delete_all/1` send one request and let the server do
  the work from the filters:

      Zizq.query(MyApp.Zizq)
      |> Zizq.Query.where(queue: "emails", status: :scheduled)
      |> Zizq.Query.update_all(ready_at: nil)

  Give the query a `limit/2` or an `in_pages_of/2` and they work a
  page at a time instead, acting on each page by id — so ten million
  jobs become a run of bounded requests rather than one enormous one:

      Zizq.query(MyApp.Zizq)
      |> Zizq.Query.where(queue: "emails", status: :dead)
      |> Zizq.Query.in_pages_of(1_000)
      |> Zizq.Query.delete_all()

  Each page's ids are sent *with* the original filters rather than
  instead of them, so a job that stopped matching between being listed
  and being acted on is left alone. The count returned is the total
  across every batch either way.

## 0.6.0-alpha.7

Completes the API: jobs can now be read, changed and deleted — one at
a time or in bulk — listed and counted, their failure history read,
and their cron schedules managed.

### Added

- **Reading, changing and deleting one job.** `Zizq.get_job/2`,
  `Zizq.update_job/3` and `Zizq.delete_job/2`, each taking a
  `Zizq.Job` or an id:

      Zizq.update_job(job, MyApp.Zizq, queue: "urgent", priority: 0)

  Updates are a merge patch, so the three states are distinct: an
  option left out leaves that field alone, `nil` clears it to the
  server's default, and a value sets it.

      # Retry with whatever the server's default limit now is.
      Zizq.update_job(job, MyApp.Zizq, retry_limit: nil)

  `:queue` and `:priority` have no default to clear to, so `nil` there
  is rejected with a message saying to omit the option instead.
  `:retention` merges field by field, so naming `:completed` leaves
  `:dead` as it was.

- **Listing and counting jobs.** `Zizq.list_jobs/2` returns a
  `Zizq.JobPage`; follow it with `Zizq.next_page/2` and
  `Zizq.prev_page/2`. `Zizq.count_jobs/2` counts without listing, and
  `Zizq.list_queues/1` reports the queues jobs have named.

      Zizq.list_jobs([queue: "emails", status: [:ready]], MyApp.Zizq)

  `Zizq.Filter` documents the filters, which every selecting endpoint
  shares. Ranges are inclusive and take a number, a `Range`, or
  `[min: _, max: _]` — Elixir has no open-ended `Range`, so one-sided
  bounds are given as keywords:

      priority: 5           # exactly 5
      priority: 1..10       # 1 to 10
      priority: [min: 5]    # 5 and above

  Pages are followed by the links the server supplies.

- **Changing and deleting jobs in bulk.** `Zizq.update_all_jobs/2` and
  `Zizq.delete_all_jobs/2`, selecting with the same filters and
  returning how many were affected:

      Zizq.update_all_jobs(
        [where: [queue: "emails", status: :scheduled], apply: [ready_at: nil]],
        MyApp.Zizq
      )

  The halves are named because both are keyword lists sharing keys —
  `queue:` and `priority:` mean something on each side — so a
  transposition could otherwise change the wrong jobs rather than
  fail. Filters restrict the operation the way a `WHERE` clause does,
  and are optional for the same reason.

- **Reading why a job failed.** `Zizq.list_errors/3` returns a
  `Zizq.ErrorPage` of `Zizq.ErrorRecord`s, one per failed attempt, and
  `Zizq.get_error/3` reads a single attempt.

      Zizq.list_errors(job, MyApp.Zizq)

  Note that a record's `:attempt` numbers the attempt it belongs to,
  counting from 1, while a `Zizq.Job`'s `:attempts` counts attempts
  already finished — so a handler on its first run sees `0`, and its
  failure is recorded as attempt `1`.

- **Cron schedules.** `Zizq.Cron` is both what you build and what the
  server returns, so installing and amending are the same shape:

      Zizq.Cron.new("my_app",
        entries: [
          [name: "nightly_cleanup",
           expression: "0 3 * * *",
           job: MyApp.Cleanup.new(%{})]
        ]
      )
      |> Zizq.replace_cron(MyApp.Zizq)

  Installing is atomic and idempotent, so every instance of an
  application can do it on boot without coordinating. Entries left out
  are removed, so a `Zizq.Cron` is the whole schedule rather than an
  addition to it — which is what makes running it on every boot
  converge rather than accumulate.

  An entry's job is an ordinary `Zizq.Enqueue`, so anything that can
  be enqueued can be scheduled, including a job built by a
  `Zizq.JobKind` module.

  Also `Zizq.get_cron/2`, `Zizq.list_crons/1`, `Zizq.delete_cron/2`,
  `Zizq.delete_all_crons/1`, and `Zizq.pause_cron/2` /
  `Zizq.resume_cron/2`. A schedule can be amended with
  `Zizq.Cron.put_entry/2` and `Zizq.Cron.delete_entry/2` and put back,
  which suits one-off changes; `Zizq.pause_cron_entry/2` and
  `Zizq.delete_cron_entry/2` change a single entry in one request.

- **`Zizq.erase_all_data/1`.** Deletes every job and every cron
  schedule in one request, for tests and development that want a
  known-empty server between scenarios:

      Zizq.erase_all_data(MyApp.Zizq)

### Notes

- Cron, unique keys and batching are Pro-licensed features. Without a
  licence the server responds 403, which is surfaced as
  `%Zizq.Error{reason: :forbidden}`.

## 0.6.0-alpha.6

Adds observability and test support: telemetry events for jobs,
enqueues and the worker's take stream, and helpers for asserting on
what was enqueued without a server. The query and cron endpoints are
still to come.

### Added

- **Telemetry events.** Attach with `:telemetry.attach_many/4`, or
  point `Telemetry.Metrics` at them. Nothing needs configuring, and an
  event with no handlers costs only the emit:

  | Event | Shape |
  | --- | --- |
  | `[:zizq, :job, :start \| :stop \| :exception]` | span, one per job |
  | `[:zizq, :enqueue, :start \| :stop \| :exception]` | span, one per call |
  | `[:zizq, :stream, :connect \| :disconnect]` | single event |

  Job events carry `:worker`, `:id`, `:type`, `:queue` and
  `:attempts`, and `:stop` adds an `:outcome` of `:ok`, `:error`,
  `:cancel`, `:snooze` or `:unknown` — so a counter does not have to
  work out for itself which returns were failures. A handler that
  raises produces `:exception` instead of `:stop`, meaning a count of
  `:stop` alone undercounts.

  Enqueue events are one span per *call*, not per job: a bulk enqueue
  of a thousand jobs is one request and one span, with `:count` set
  and `:type`/`:queue` `nil`. A rejected enqueue returns an error
  rather than raising, so it arrives as a `:stop` carrying
  `outcome: :error` and the `Zizq.Error` — count both that and
  `:exception` to catch every failure.

  `Zizq.Telemetry` documents every event and its metadata.

- **`Zizq.Testing`.** Assert on what your code enqueued, and run
  handlers, without a server:

      defmodule MyApp.SignupTest do
        use ExUnit.Case, async: true
        use Zizq.Testing, client: MyApp.Zizq

        test "signing up sends a welcome email" do
          MyApp.Signup.run("ada@example.com")

          assert_enqueued(type: "send_email", payload: %{"template" => "welcome"})
        end
      end

  Start the recorder once in `test/test_helper.exs` with
  `Zizq.Testing.start_link()`.

  A client set up this way records enqueues instead of sending them,
  and answers with a `Zizq.Job` as the server would. The diversion
  happens at the request itself, so everything above it runs
  unchanged — option validation, payload-derived unique and batch
  keys, and telemetry all behave as they do in production.

  Recordings belong to the test that made them rather than to the
  client, so a fixed client name is safe under `async: true`.
  Enqueues from a `Task` count too: `$callers` is followed to find the
  test that started it.

  Alongside `assert_enqueued/1`, `refute_enqueued/1` and
  `all_enqueued/1`:

    * `perform_job/3` runs one handler and returns what it returned,
      including `{:error, reason}`, so a test asserts on the outcome
      rather than on what a worker would have made of it.
    * `drain_enqueued/2` runs every enqueued job through a handler or
      a `Zizq.Router` and returns how many ran. `recursive: true`
      keeps going until nothing new is enqueued, for handlers that
      enqueue further work, bounded by `:max_iterations`.

  Payloads are normalised through JSON on the way in, exactly as they
  are on the way to a real server, so a payload enqueued as
  `%{user_id: 1}` records and matches as `%{"user_id" => 1}` — and a
  handler under `perform_job/3` receives the string keys it would
  receive in production.

  Both `perform_job/3` and `drain_enqueued/2` fail the test if a
  handler returns something Zizq does not recognise. A worker
  acknowledges such a job and logs a warning, since by then the work
  is done; a test is where that is cheapest to catch.

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
