# Testing

`Zizq.Testing` lets a test assert on what your code enqueued, and run job
handlers directly, both without a server running.

Two things are usually worth testing, and they are separate concerns:

- **That the right job was enqueued.** Your signup code should enqueue a
  welcome email; whether the email sends is the email job's business.
- **That a handler does its job.** Given a payload, `perform/1` should do the
  right thing and return the right outcome.

The first is `assert_enqueued/1`. The second is `perform_job/3`. Neither needs
a queue server.

## Setting up

Start the recorder once, in `test/test_helper.exs`, before `ExUnit.start()`:

> Elixir:
>
> ```elixir
> {:ok, _} = Zizq.Testing.start_link()
>
> ExUnit.start()
> ```

Then in a case, name the client your code enqueues through:

> Elixir:
>
> ```elixir
> defmodule MyApp.SignupTest do
>   use ExUnit.Case, async: true
>   use Zizq.Testing, client: MyApp.Zizq
>
>   test "signing up sends a welcome email" do
>     MyApp.Signup.run("ada@example.com")
>
>     assert_enqueued(type: "send_email", payload: %{"template" => "welcome"})
>   end
> end
> ```

`use Zizq.Testing` adds a `setup` that points the client at the recorder for
each test, and imports the assertions bound to it. Nothing needs passing
around, and there is nothing to reset between tests.

> [!NOTE]
> The client name is the one your **application code** uses. Nothing in the
> test refers to it again — that is the point. Your code calls
> `Zizq.enqueue(job, MyApp.Zizq)` exactly as it does in production.

## Enqueues are recorded, not sent

A client set up this way handles enqueues in memory instead of contacting a
server, and hands back a `Zizq.Job` as the server would — with a synthetic id,
`status: :ready` and `attempts: 0`.

Everything upstream of the request runs unchanged. Option validation,
payload-derived unique keys, batch key derivation and telemetry all behave
exactly as they do in production, because the code under test takes the same
path right up to the point the request would have been sent:

> Elixir:
>
> ```elixir
> test "a malformed enqueue still fails" do
>   assert_raise ArgumentError, fn ->
>     Zizq.enqueue([type: "send_email", payloads: %{}], MyApp.Zizq)
>   end
> end
> ```

## Recordings are per test

Recordings belong to the **test process that made them**, not to the client,
so a fixed client name is safe under `async: true`. Two tests naming the same
client cannot see each other's enqueues.

Enqueues from a `Task` count too, as long as the process was started from the
test — `$callers` is followed to find the owner, however deep the chain:

> Elixir:
>
> ```elixir
> test "enqueues from a task are attributed to the test" do
>   Task.async(fn -> MyApp.Signup.run("ada@example.com") end) |> Task.await()
>
>   assert_enqueued(type: "send_email")
> end
> ```

A process started **outside** that chain is not attributable, and its enqueues
are not recorded. That covers anything in your application's supervision tree
— a `GenServer` started at boot has no caller chain leading back to a test.
Where that matters, have the test call the code directly rather than poke a
long-lived process into doing it.

## Asserting

`assert_enqueued/1` and `refute_enqueued/1` take a subset of the fields to
match on. A job matches when **every** field given matches:

> Elixir:
>
> ```elixir
> assert_enqueued(type: "send_email")
> assert_enqueued(type: "send_email", queue: "emails")
> assert_enqueued(payload: %{"user_id" => 42})
>
> refute_enqueued(type: "send_sms")
> ```

A `:payload` matches when the recorded payload **contains** what was given, so
a test names the keys it cares about and ignores the rest:

> Elixir:
>
> ```elixir
> # Enqueued with a user_id, a template and a request id.
> assert_enqueued(payload: %{"template" => "welcome"})
> ```

Every other field is compared for equality against the value as it would have
gone over the wire, so `priority: 0` and `unique_key: "user:42"` work as you
would expect.

A failed assertion prints what was actually enqueued, which is usually enough
to see the problem without reaching for `IO.inspect/1`:

> Output:
>
> ```
> Expected a job matching:
>
> [type: "send_email", queue: "urgent"]
>
> Enqueued jobs were:
>
> [%{"type" => "send_email", "queue" => "emails", "payload" => %{"user_id" => 42}, ...}]
> ```

### Anything the assertions do not cover

`all_enqueued/1` returns the matching enqueues, oldest first, as the
string-keyed maps that would have been sent:

> Elixir:
>
> ```elixir
> assert [email] = all_enqueued(type: "send_email")
> assert email["payload"]["user_id"] == 42
>
> assert length(all_enqueued()) == 3
> ```

Use it for anything positional or numeric — ordering, counts, "the second one
should be scheduled for later" — where the default matching doesn't cover your
needs.

### Asserting on a second action

A refutation sees everything the test has recorded, not just what the last
call did. So a test that acts twice needs to forget the first action before it
can say anything about the second:

> Elixir:
>
> ```elixir
> test "rescanning a sitemap enqueues nothing new" do
>   MyApp.Sitemap.scan(sitemap)
>   assert_enqueued(type: "check_url")
>
>   clear_enqueued()
>
>   MyApp.Sitemap.scan(sitemap)
>   refute_enqueued(type: "check_url")
> end
> ```

Without `clear_enqueued/0` that refutation always fails, and reads as a bug in
the code rather than in the test. Clearing is scoped to the test that calls
it, so it stays safe under `async: true`.

## Payloads are what the server would have stored

A payload is normalised through JSON on the way in, exactly as it is on the
way to a real server. So a payload enqueued with atom keys records and matches
as string-keyed:

> Elixir:
>
> ```elixir
> MyApp.SendEmail.new(%{user_id: 42}) |> Zizq.enqueue(MyApp.Zizq)
>
> assert_enqueued(payload: %{"user_id" => 42})   # matches
> refute_enqueued(payload: %{user_id: 42})       # does not
> ```

The same applies to a payload handed to `perform_job/3`. A handler receives
string keys here because it receives string keys in production — without that,
a test could pass `%{user_id: 1}`, match a clause production would never
reach, and go green on a handler that cannot run.

## Running a handler

`perform_job/3` runs a job's handler directly, with no worker and no server:

> Elixir:
>
> ```elixir
> test "sends the email" do
>   assert :ok = perform_job(MyApp.SendEmail, %{"user_id" => 42})
> end
> ```

It returns whatever the handler returned, **verbatim**, so a test asserts on
the outcome rather than on what a worker would have done with it:

> Elixir:
>
> ```elixir
> assert {:error, :smtp_down} = perform_job(MyApp.SendEmail, %{"user_id" => 42})
> assert {:cancel, :gone}     = perform_job(MyApp.SendEmail, %{"user_id" => 99})
> assert {:snooze, 300_000}   = perform_job(MyApp.SendEmail, %{"user_id" => 7})
> ```

Anything the handler raises propagates, so `assert_raise/2` works normally.

A `Zizq.Router` can be performed instead of a module, which needs a `:type`
since that is what a router dispatches on:

> Elixir:
>
> ```elixir
> router = Zizq.Router.new([MyApp.SendEmail, MyApp.SendSms])
>
> assert :ok = perform_job(router, %{"user_id" => 42}, type: "send_email")
> ```

### The job a handler sees

A `perform/2` handler receives a `Zizq.Job`, and its fields can be set:

> Elixir:
>
> ```elixir
> # Exercise the retry-specific branch.
> assert :ok = perform_job(MyApp.SendEmail, %{"user_id" => 42}, attempts: 3)
>
> # And the rest.
> perform_job(MyApp.SendEmail, payload, id: "job_123", queue: "urgent", attempts: 0)
> ```

`:attempts` counts attempts already **finished**, so it defaults to `0` — a
first run. A guard like `when attempts >= 3` first matches on the fourth, so
that is the number to pass to reach it.

### An unrecognised return fails the test

A worker acknowledges a return value it does not recognise as complete and
logs a warning. Here it is an assertion failure instead:

> Output:
>
> ```
> The handler returned a value Zizq does not recognise:
>
> :error
>
> Expected one of:
>
>   :ok
>   {:ok, value}
>   {:error, reason}
>   {:cancel, reason}
>   {:snooze, milliseconds} or {:snooze, %DateTime{}}
> ```

A test is the cheapest place to catch `:error` where `{:error, reason}` was
meant — in production that job is quietly marked complete and the failure
never surfaces.

## Draining

`drain_enqueued/2` runs every job the test enqueued through a handler, and
returns how many ran. That tests a producer and its consumers together:

> Elixir:
>
> ```elixir
> test "signing up sends the welcome email" do
>   MyApp.Signup.run("ada@example.com")
>
>   assert drain_enqueued(Zizq.Router.new([MyApp.SendEmail])) == 1
>   assert MyApp.Mailer.delivered() == ["ada@example.com"]
> end
> ```

The handler is exactly what a worker takes: a `Zizq.Router`, or a one-argument
function over a `Zizq.Job`. A plain function is often enough when the test only
needs to see what came through:

> Elixir:
>
> ```elixir
> drain_enqueued(fn job ->
>   send(self(), {:ran, job.type, job.payload})
>   :ok
> end)
> ```

Handlers run **in the calling process, one at a time, in the order the jobs
were enqueued** — so a test can reason about ordering in a way a real worker's
concurrency would not allow. Anything a handler raises propagates.

A job is drained once. Calling again runs only what has been enqueued since:

> Elixir:
>
> ```elixir
> MyApp.Signup.run("ada@example.com")
> assert drain_enqueued(handler) == 1
> assert drain_enqueued(handler) == 0
> ```

### Jobs that enqueue jobs

By default a drain runs only what was already enqueued when the call began, so
a handler that enqueues further work leaves it for the next call. That is what
you want when the point is to check one step at a time.

`recursive: true` keeps going until nothing new is enqueued:

> Elixir:
>
> ```elixir
> MyApp.Import.start(file)
>
> # Runs the import job, the page jobs it fans out, and so on.
> assert drain_enqueued(router, recursive: true) == 42
> ```

`:max_iterations` guards against a handler that always enqueues and would
otherwise hang the suite. It defaults to `1_000` and failing it says so
plainly rather than timing out.

### Draining part of what was enqueued

`:type` and `:queue` restrict what runs, matching as `assert_enqueued/1` does:

> Elixir:
>
> ```elixir
> drain_enqueued(handler, type: "send_email")
> drain_enqueued(handler, queue: "emails")
> ```

Useful when a test wants to run one kind of job and assert that another was
enqueued but left alone.

## Limitations

**Only enqueuing is recorded.** Every other endpoint raises, with an
explanation rather than a plausible-looking empty answer:

> Output:
>
> ```
> /jobs/123/success is not supported by Zizq.Testing.
>
> Only enqueuing is recorded. Acknowledging or streaming a job needs
> a server to have delivered one — run those against a real server,
> or call your handler directly with perform_job/2.
> ```

Acknowledging or streaming a job needs a server to have delivered one, so
there is nothing honest to return. Failing loudly beats a test that passes
against a fiction.

**Nothing here talks to a server**, so it cannot tell you that the server
accepts your `unique_key`, that a batch folds the way you meant, or that a
cron expression parses. Those are integration concerns — run them against a
real server, which is cheap to start:

> Command:
>
> ```bash
> $ zizq serve --root-dir /tmp/zizq-test
> ```

Then point a client at it and use `Zizq.erase_all_data/1` between scenarios.

> [!TIP]
> The two levels answer different questions and both are worth having. Unit
> tests say your code enqueues the right job and your handlers do the right
> thing; a handful of integration tests say the wire contract holds. Neither
> substitutes for the other.
