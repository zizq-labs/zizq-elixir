# Enqueuing Jobs

Enqueuing takes the job first and the client second, so it pipes:

> Elixir:
>
> ```elixir
> MyApp.SendEmail.new(%{"user_id" => 42})
> |> Zizq.enqueue(MyApp.Zizq)
> #=> {:ok, %Zizq.Job{id: "03gn…", queue: "emails", status: :ready}}
> ```

The job comes back as the server recorded it, so its `:id` and any
server-assigned defaults are available immediately.

> [!NOTE]
> The returned job exposes no `:payload` — the server omits it from enqueue
> responses. Read it back with `Zizq.get_job/2` if you need it.

## Without a job module

A keyword list or map works just as well, and is all a producer needs:

> Elixir:
>
> ```elixir
> Zizq.enqueue(
>   [type: "send_email", queue: "emails", payload: %{"user_id" => 42}],
>   MyApp.Zizq
> )
> ```

Only `:type` is required. `:queue` defaults to `"default"`, and every other
option is omitted from the request so the server's own defaults apply.

Unknown keys are rejected rather than ignored:

> Elixir:
>
> ```elixir
> Zizq.enqueue([type: "send_email", payloads: %{}], MyApp.Zizq)
> ** (ArgumentError) unknown enqueue key: [:payloads]
> ```

Without that, a typo like `payloads:` would quietly enqueue a job with an
empty payload that fails somewhere else, much later.

## Per-enqueue overrides

`new/2` takes anything the module declared and overrides it for this one
enqueue:

> Elixir:
>
> ```elixir
> MyApp.SendEmail.new(%{"user_id" => 42}, priority: 0, queue: "urgent")
> |> Zizq.enqueue(MyApp.Zizq)
> ```

The module's other defaults are untouched, and the override applies only to
this job — the next `new/1` starts from the module's defaults again.

The one thing you cannot override is `:type`:

> Elixir:
>
> ```elixir
> MyApp.SendEmail.new(%{}, type: "something_else")
> ** (ArgumentError) cannot override :type when building a "send_email" job
> ```

Overriding it would route the job to a different handler than the module it
was built from, which is unlikely what was meant.

## Scheduling for later

`:ready_at` holds a job back until a given time. It takes a `DateTime` or Unix
milliseconds:

> Elixir:
>
> ```elixir
> # At a specific time.
> MyApp.SendEmail.new(%{"user_id" => 42}, ready_at: ~U[2026-09-01 09:00:00Z])
> |> Zizq.enqueue(MyApp.Zizq)
>
> # In an hour.
> at = DateTime.add(DateTime.utc_now(), 3_600, :second)
> MyApp.SendEmail.new(%{"user_id" => 42}, ready_at: at)
> |> Zizq.enqueue(MyApp.Zizq)
> ```

The job is stored with status `:scheduled` and becomes `:ready` when the time
arrives. No worker holds it in the meantime, so scheduling a year out costs
nothing but a row.

> [!TIP]
> For work that repeats on a timetable rather than once at a known moment, use
> [Cron Scheduling](./cron.md) instead. A cron entry survives restarts and
> does not need something to enqueue it each time.

## Bulk enqueue

`Zizq.enqueue_all/2` sends many jobs in **one** request, atomically, which is
significantly faster due to reduced network overhead:

> Elixir:
>
> ```elixir
> users
> |> Enum.map(&MyApp.SendEmail.new(%{"user_id" => &1.id}))
> |> Zizq.enqueue_all(MyApp.Zizq)
> #=> {:ok, [%Zizq.Job{}, %Zizq.Job{}, ...]}
> ```

Elements may be `Zizq.Enqueue` structs, keyword lists or maps, mixed freely —
they need not all be the same kind of job:

> Elixir:
>
> ```elixir
> [
>   MyApp.SendEmail.new(%{"user_id" => 42}),
>   [type: "generate_report", queue: "reports", payload: %{"id" => 7}]
> ]
> |> Zizq.enqueue_all(MyApp.Zizq)
> ```

Jobs come back in the order they were sent, so a returned job lines up with
the input that produced it. An empty list short-circuits without contacting
the server at all.

Prefer this to a loop over `enqueue/2` for anything more than a handful. One
request of a thousand jobs is dramatically cheaper than a thousand requests,
and it either all lands or none of it does.

## Raising instead of returning

Every enqueue function has a `!` variant that raises `Zizq.Error` rather than
returning `{:error, _}`:

> Elixir:
>
> ```elixir
> job = Zizq.enqueue!([type: "send_email"], MyApp.Zizq)
> jobs = Zizq.enqueue_all!(enqueues, MyApp.Zizq)
> ```

That suits call sites where a failed enqueue should abort the surrounding
work — inside an `Ecto.Multi`, or anywhere the alternative is `{:error, _}`
propagating up as a surprise.

## Handling failures

An enqueue that the server rejects comes back as an error, not an exception:

> Elixir:
>
> ```elixir
> case Zizq.enqueue(job, MyApp.Zizq) do
>   {:ok, job} ->
>     job
>
>   {:error, %Zizq.Error{reason: :forbidden}} ->
>     # A licensed feature, on a server without a licence.
>     needs_a_licence()
>
>   {:error, %Zizq.Error{} = error} ->
>     Logger.error(Exception.message(error))
> end
> ```

Every failure is a `Zizq.Error` carrying a `:reason` atom, so a guard covers a
whole class at once:

> Elixir:
>
> ```elixir
> {:error, %Zizq.Error{reason: reason}} when reason in [:transport, :server_error] ->
>   retry_later()
> ```

`Zizq.Error.retryable?/1` answers that question directly — true only for
`:transport` and `:server_error`, the two cases where trying again could
plausibly succeed.

> [!NOTE]
> A malformed enqueue raises `ArgumentError` rather than returning an error.
> That is a bug in the calling code, not a runtime condition to handle, and it
> is caught before any request is made.

## Duplicates and batches

When a job uses [uniqueness](./unique-jobs.md) or [batching](./batched-jobs.md),
an enqueue may match something already on the server. That is still a success
— the existing job comes back, flagged:

> Elixir:
>
> ```elixir
> {:ok, job} = Zizq.enqueue(enqueue, MyApp.Zizq)
>
> job.duplicate  #=> true, if a unique job was already queued
> job.folded     #=> true, if this was folded into an existing batch
> ```

Both are `false` on a job that was genuinely created. Checking them is
optional; the point is that a duplicate is not an error to handle.
