# Cron Scheduling

> [!NOTE]
> This feature requires a Zizq [pro license](https://zizq.io/pricing) on the
> server. Without one the server responds 403, which arrives as
> `%Zizq.Error{reason: :forbidden}`.

A cron schedule enqueues jobs on a timetable. Schedules live on the server, so
they survive restarts and do not need anything running to trigger them.

A schedule is a **named group** of entries, and is installed as a whole:

> Elixir:
>
> ```elixir
> Zizq.Cron.new("my_app",
>   entries: [
>     [name: "nightly_cleanup",
>      expression: "0 3 * * *",
>      job: MyApp.Cleanup.new(%{})],
>     [name: "digest",
>      expression: "*/15 * * * *",
>      timezone: "Australia/Melbourne",
>      job: [type: "digest", queue: "reports"]]
>   ]
> )
> |> Zizq.replace_cron(MyApp.Zizq)
> ```

## Installing at startup

The natural place for that call is application startup. Installing is
**atomic and idempotent**, so every instance of an application can do it on
boot without coordinating — none of them needs to be designated the one that
owns the schedule.

> Elixir:
>
> ```elixir
> defmodule MyApp.Application do
>   use Application
>
>   @impl true
>   def start(_type, _args) do
>     children = [
>       {Zizq, name: MyApp.Zizq, url: "http://127.0.0.1:7890"}
>     ]
>
>     result = Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
>
>     install_schedule()
>
>     result
>   end
>
>   defp install_schedule do
>     Zizq.Cron.new("my_app", entries: MyApp.Schedule.entries())
>     |> Zizq.replace_cron(MyApp.Zizq)
>   end
> end
> ```

**Entries left out are removed.** What you pass is the whole schedule rather
than an addition to it, which is exactly what makes running it on every boot
converge rather than accumulate. Delete an entry from your code, deploy, and
it is gone from the server.

> [!TIP]
> Keep the schedule in code next to the jobs it runs. It is then reviewed like
> anything else, and there is no separate place for it to drift from.

## Entries

An entry pairs a cron expression with a job to enqueue:

- **`:name`** — unique within the group, and how the entry is addressed later.
- **`:expression`** — a cron expression, e.g. `"*/15 * * * *"`.
- **`:job`** — what to enqueue. An ordinary `Zizq.Enqueue`, so anything you
  can enqueue you can schedule.
- **`:timezone`** — an IANA name such as `"Australia/Melbourne"`. Its group's
  timezone when unset, or the server's own when the group does not name one
  either.
- **`:paused`** — whether the entry starts suspended.

Because the job is an ordinary enqueue, a job module works directly:

> Elixir:
>
> ```elixir
> [name: "nightly_cleanup", expression: "0 3 * * *", job: MyApp.Cleanup.new(%{"scope" => "all"})]
> ```

And so does a plain keyword list (e.g. for a job handled by another service or
another language):

> Elixir:
>
> ```elixir
> [name: "reindex", expression: "0 4 * * *", job: [type: "reindex", queue: "search"]]
> ```

> [!NOTE]
> An entry's job cannot set `:ready_at` — the expression already decides when
> it runs, and two answers to one question is rejected at the call site.

### Timezones

Most schedules want one timezone throughout, which is what the group's
`:timezone` is for. Specify it once, and every entry that does not specify its
own is evaluated in it:

> Elixir:
>
> ```elixir
> Zizq.Cron.new("my_app",
>   timezone: "Australia/Melbourne",
>   entries: [
>     [name: "nightly_cleanup", expression: "0 3 * * *", job: MyApp.Cleanup.new(%{})],
>     [name: "digest", expression: "0 9 * * *", job: [type: "digest", queue: "reports"]]
>   ]
> )
> ```

An entry specifying its own timezone uses that instead, so one schedule can
hold entries in several zones:

> Elixir:
>
> ```elixir
> [name: "eu_digest", expression: "0 9 * * *", timezone: "Europe/Rome", job: ...]
> ```

With neither set, the server evaluates the expression in its own local
timezone.

The group's timezone lives on the server as the group's, so a schedule read
back with `Zizq.get_cron/2` still says where it came from — it is not copied
onto each entry.

> [!NOTE]
> A group-level timezone needs Zizq 0.7.0 or newer on the server. Against an
> older server it is ignored, and entries that rely on it fall back to the
> server's local timezone.

## Building a schedule

`Zizq.Cron.new/2` takes the entries all at once, as above. `put_entry/2` adds
them one at a time, which suits building a schedule conditionally:

> Elixir:
>
> ```elixir
> schedule =
>   Zizq.Cron.new("my_app")
>   |> Zizq.Cron.put_entry(name: "nightly", expression: "0 3 * * *", job: MyApp.Cleanup.new(%{}))
>   |> Zizq.Cron.put_entry(name: "digest", expression: "0 9 * * *", job: MyApp.Digest.new(%{}))
>
> schedule =
>   if Application.get_env(:my_app, :send_reports?) do
>     Zizq.Cron.put_entry(schedule, name: "reports", expression: "0 6 * * 1", job: ...)
>   else
>     schedule
>   end
>
> Zizq.replace_cron(schedule, MyApp.Zizq)
> ```

`put_entry/2` replaces an entry of the same name rather than appending.

## Reading a schedule

> Elixir:
>
> ```elixir
> {:ok, schedule} = Zizq.get_cron("my_app", MyApp.Zizq)
>
> schedule.paused                              #=> false
> schedule.timezone                            #=> "Australia/Melbourne"
> Enum.map(schedule.entries, & &1.name)        #=> ["nightly_cleanup", "digest"]
>
> entry = Zizq.Cron.entry(schedule, "digest")
> entry.expression                             #=> "*/15 * * * *"
> entry.next_enqueue_at                        #=> ~U[2026-08-15 09:15:00Z]
> entry.last_enqueue_at                        #=> ~U[2026-08-15 09:00:00Z]
> ```

`Zizq.list_crons/1` lists the group names on the server.

## Amending a schedule

The same struct is both what you build and what the server returns, so a
schedule can be read, changed and put back:

> Elixir:
>
> ```elixir
> Zizq.get_cron!("my_app", MyApp.Zizq)
> |> Zizq.Cron.delete_entry("nightly_cleanup")
> |> Zizq.Cron.put_entry(name: "weekly_cleanup", expression: "0 3 * * 0", job: MyApp.Cleanup.new(%{}))
> |> Zizq.replace_cron(MyApp.Zizq)
> ```

That reads and writes as two steps, so it suits a one-off change made by one
operator. To change one entry from running application code, where several
instances might do it at once, use the per-entry calls below — they change one
entry in a single request.

## Pausing and resuming

A paused group fires nothing, whatever its entries say:

> Elixir:
>
> ```elixir
> Zizq.pause_cron("my_app", MyApp.Zizq)
> Zizq.resume_cron("my_app", MyApp.Zizq)
> ```

A single entry can be suspended while the rest of the schedule keeps running:

> Elixir:
>
> ```elixir
> Zizq.pause_cron_entry([cron: "my_app", entry: "digest"], MyApp.Zizq)
> Zizq.resume_cron_entry([cron: "my_app", entry: "digest"], MyApp.Zizq)
> ```

For clarity, the group and entry are named rather than positional.

> [!TIP]
> Pausing is the safe way to stop a scheduled job in an incident. It changes
> only that entry, on the server, and leaves the schedule your application
> installs at boot untouched — so a redeploy will not silently resume it, but
> nor will it be lost.

Entries can also be installed already paused, for something staged ahead of
being switched on:

> Elixir:
>
> ```elixir
> [name: "new_report", expression: "0 6 * * *", paused: true, job: ...]
> ```

## Deleting

> Elixir:
>
> ```elixir
> # One entry.
> Zizq.delete_cron_entry([cron: "my_app", entry: "digest"], MyApp.Zizq)
>
> # The whole schedule.
> Zizq.delete_cron("my_app", MyApp.Zizq)
>
> # Every schedule on the server.
> Zizq.delete_all_crons(MyApp.Zizq)
> ```

Deleting a schedule stops future enqueues. Jobs it has already enqueued are
unaffected and run as normal.

## Jobs enqueued by cron

A scheduled job is an ordinary job once enqueued — same queue, same worker,
same retries, same everything. Nothing special is needed to run one:

> Elixir:
>
> ```elixir
> {Zizq.Worker,
>  client: MyApp.Zizq,
>  queues: ["reports"],
>  handler: Zizq.Router.new([MyApp.Digest])}
> ```

Which also means a cron entry can target a job type handled by a worker in
another language entirely.
