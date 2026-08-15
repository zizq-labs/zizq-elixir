# Querying & Managing Jobs

Everything the server holds can be read back and changed. Jobs can be listed
and counted, one job can be fetched or edited, thousands can be changed at
once, and a job's failure history read attempt by attempt.

There are valid approaches, and they share one vocabulary of filters:

- **`Zizq.query/1`** builds a composable query that paginates for you and
  works with `Enum` and `Stream`. This is likely what you want most of the
  time.
- **The functions directly on the `Zizq` module** — `list_jobs/2`,
  `count_jobs/2`, `update_all_jobs/2` etc take the same filters and handle
  exactly one request each.

> Elixir:
>
> ```elixir
> # Composable.
> Zizq.query(MyApp.Zizq)
> |> Zizq.Query.where(queue: "emails", status: :dead)
> |> Enum.take(10)
>
> # Direct.
> Zizq.list_jobs([queue: "emails", status: :dead, limit: 10], MyApp.Zizq)
> ```

## Building a query

`Zizq.query/1` builds a query and **sends nothing**. Nothing reaches the
server until the query is enumerated, counted, or run through `update_all/2`
or `delete_all/1`:

> Elixir:
>
> ```elixir
> query =
>   Zizq.query(MyApp.Zizq)
>   |> Zizq.Query.where(queue: "emails")
>   |> Zizq.Query.where(status: :dead)
>   |> Zizq.Query.order(:desc)
>
> # Still nothing has happened.
> Enum.count(query)  #=> now one request
> ```

`where/2` merges with what is already there and **later calls win per key**,
so a query can be built in pieces and a base reused:

> Elixir:
>
> ```elixir
> base = Zizq.query(MyApp.Zizq) |> Zizq.Query.where(queue: "emails")
>
> dead    = Zizq.Query.where(base, status: :dead)
> waiting = Zizq.Query.where(base, status: [:ready, :scheduled])
> ```

Queries are immutable, so `base` is unchanged by either.

There is one `where/2` rather than a `by_queue`, `by_status`, `by_type` and so
on. The filters are already a keyword list and the server takes them as one
set, so a function per field would add names without adding meaning.

> [!NOTE]
> Filters are validated **as the query is built**, not when it runs. A typo
> raises `ArgumentError` at the `where/2` that made it, rather than several
> pipeline stages later.

## Filters

The same options narrow every job-selecting call — queries, listings, counts,
and the bulk operations. They are documented once in
[`Zizq.Filter`](https://hexdocs.pm/zizq/Zizq.Filter.html):

Filter | Takes | Matches
--- | --- | ---
`:id` | a job id, or a list | those jobs
`:queue` | a name, or a list | jobs on any of those queues
`:type` | a type, or a list | jobs of any of those types
`:status` | a status atom, or a list | jobs in any of those statuses
`:priority` | a number, `Range`, or `[min: _, max: _]` | that range, inclusive
`:ready_at` | the same, over `DateTime`s or milliseconds | that window
`:attempts` | the same, over attempt counts | that range
`:filter` | a jq expression string | jobs whose payload satisfies it

An option left out narrows nothing. A list matches **any** of its members:

> Elixir:
>
> ```elixir
> Zizq.Query.where(query, status: [:ready, :scheduled], queue: ["emails", "sms"])
> ```

Statuses are `:scheduled`, `:ready`, `:in_flight`, `:completed` and `:dead`.

> [!NOTE]
> A completed job is purged the instant it finishes unless its
> [retention](./defining-jobs.md#retention-policy) says otherwise, so
> `status: :completed` finds nothing on a server left at its defaults. That
> is a configuration answer, not a query one.

### Ranges

Ranges are inclusive at both ends, and a bare number matches exactly:

> Elixir:
>
> ```elixir
> priority: 5             # exactly 5
> priority: 1..10         # 1 to 10
> priority: [min: 5]      # 5 and above
> priority: [max: 5]      # 5 and below
> ```

`:ready_at` takes `DateTime`s as well as milliseconds, so a window reads as
one:

> Elixir:
>
> ```elixir
> # Scheduled for some point in the next hour.
> Zizq.Query.where(query,
>   status: :scheduled,
>   ready_at: [min: DateTime.utc_now(), max: DateTime.add(DateTime.utc_now(), 1, :hour)]
> )
> ```

An open end is simply an omitted bound. Stepped ranges are rejected —
`1..10//2` has no meaning to the server, so it raises here rather than being
silently flattened.

### Filtering on the payload

`:filter` is a jq expression evaluated against each job's payload. It must
produce something truthy:

> Elixir:
>
> ```elixir
> # One customer's jobs.
> Zizq.Query.where(query, filter: ".customer_id == 42")
>
> # Jobs whose payload has a non-empty list of recipients.
> Zizq.Query.where(query, filter: "(.recipients | length) > 0")
>
> # Combined with the ordinary filters.
> Zizq.Query.where(query, queue: "emails", status: :dead, filter: ~s(.template == "welcome"))
> ```

This is the one filter the server can never answer from an index — it reads
each candidate payload — so narrow with `:queue`, `:type` or `:status`
alongside it where you can.

> [!TIP]
> jq returns `null` for a missing key rather than erroring, and `null` is
> falsey, so `.customer_id == 42` quietly matches nothing when the field is
> actually called `.customerId`. If a filter finds nothing you expected,
> check a payload with `Zizq.get_job/2` first.

## Running a query

A query is `Enumerable`, so `Enum` and `Stream` work on it directly, and pages
are fetched **as they are needed and no further**:

> Elixir:
>
> ```elixir
> # Stops after the first page — Enum.take/2 stops asking.
> Zizq.query(MyApp.Zizq)
> |> Zizq.Query.where(queue: "emails")
> |> Enum.take(10)
>
> # Walks every page.
> Zizq.query(MyApp.Zizq)
> |> Zizq.Query.where(queue: "emails")
> |> Enum.each(&IO.inspect/1)
>
> # Lazily, one job at a time.
> Zizq.query(MyApp.Zizq)
> |> Zizq.Query.where(status: :dead)
> |> Stream.map(& &1.id)
> |> Stream.chunk_every(100)
> |> Enum.each(&archive/1)
> ```

Each job is a `Zizq.Job`, carrying its `:payload`.

> [!WARNING]
> A query **raises** `Zizq.Error` on a failed request rather than returning
> `{:error, _}`. `Enumerable` has no way to hand an error back mid-stream, so
> there is nowhere for a tuple to go. Wrap a query in `try/rescue` if a
> network failure mid-listing is something you handle rather than something
> that should abort the work.

## Counting

`Enum.count/1` asks the server to count rather than fetching every page, so it
costs **one request whatever the total**:

> Elixir:
>
> ```elixir
> Zizq.query(MyApp.Zizq)
> |> Zizq.Query.where(queue: "emails", status: :dead)
> |> Enum.count()
> #=> 1_284
> ```

That is the whole reason `Zizq.Query` implements `count/1` itself rather than
letting `Enum` walk the pages. `Zizq.count_jobs/2` is the same request without
the query:

> Elixir:
>
> ```elixir
> Zizq.count_jobs([queue: "emails", status: :dead], MyApp.Zizq)
> #=> {:ok, 1_284}
> ```

A `limit/2` caps a count as it caps everything else, so counting and
enumerating always agree — `Enum.count(query)` and `length(Enum.to_list(query))`
are the same number reached by different routes.

## Ordering

`order/2` takes `:asc` (oldest first) or `:desc` (newest first). The server
defaults to `:asc`:

> Elixir:
>
> ```elixir
> Zizq.query(MyApp.Zizq)
> |> Zizq.Query.where(status: :dead)
> |> Zizq.Query.order(:desc)
> |> Enum.take(20)
> ```

That pair — `:desc` and a small `Enum.take/2` — is the "most recent failures"
query, and costs one request.

## Limits and page size

`limit/2` caps how many jobs come back **in total**. `in_pages_of/2` sets how
many are fetched **per request**. They are independent: the first is what you
want, the second is how eagerly it is fetched.

> Elixir:
>
> ```elixir
> Zizq.query(MyApp.Zizq)
> |> Zizq.Query.where(queue: "emails")
> |> Zizq.Query.limit(500)          # at most 500 jobs
> |> Zizq.Query.in_pages_of(50)     # fetched 50 at a time
> |> Enum.to_list()
> ```

A `limit/2` also caps a single request, since asking for more than the caller
wants would fetch jobs only to discard them. So `limit(10)` with no page size
is one request for ten jobs, not one for the server's default page followed by
throwing most of it away.

The server allows 1 to 2000 jobs per page and picks its own default when told
nothing.

## Working with pages

`Zizq.Query.pages/1` gives the pages themselves as a `Stream` of
`Zizq.JobPage`, for when a page at a time is the useful unit:

> Elixir:
>
> ```elixir
> Zizq.query(MyApp.Zizq)
> |> Zizq.Query.where(status: :dead)
> |> Zizq.Query.in_pages_of(500)
> |> Zizq.Query.pages()
> |> Enum.each(fn page ->
>   Logger.info("archiving #{length(page.jobs)} jobs")
>   MyApp.Archive.store(page.jobs)
> end)
> ```

### Paginating by hand

`Zizq.list_jobs/2` returns one page, and `next_page/2` follows it until there
is nothing left:

> Elixir:
>
> ```elixir
> {:ok, page} = Zizq.list_jobs([queue: "emails", limit: 100], MyApp.Zizq)
>
> page.jobs                       #=> [%Zizq.Job{}, ...]
> Zizq.JobPage.has_next?(page)    #=> true
>
> case Zizq.next_page(page, MyApp.Zizq) do
>   {:ok, nil} -> :done
>   {:ok, next} -> handle(next)
> end
> ```

The links are opaque paths the server builds, carrying the cursor **and every
filter of the original request** — so following one cannot accidentally widen
the query, which is the failure mode if a client rebuilt the URL itself.

`prev_page/2` goes the other way, returning `nil` at the start of the listing.

> [!NOTE]
> `prev_page/2` guarantees *which* jobs come back, not what order they come
> back in. At the time of writing the server returns them reversed, because
> the `prev` link carries the opposite `order` to the request that produced
> it. Sort them yourself if the order matters.

Reach for this over a query when you want to hold a cursor across something —
render a page of a web UI, hand the link to a background job — rather than
walk a listing in one pass.

## Reading one job

> Elixir:
>
> ```elixir
> Zizq.get_job(job_id, MyApp.Zizq)
> #=> {:ok, %Zizq.Job{status: :completed, payload: %{"user_id" => 42}}}
> ```

Takes an id or a `Zizq.Job`, so a job from anywhere can be refreshed. Unlike
the job returned by `Zizq.enqueue/2`, this one carries its `:payload`.

A job the server no longer holds is
`{:error, %Zizq.Error{reason: :not_found}}` — which a completed job becomes as
soon as its retention expires, immediately by default.

`get_job!/2` raises instead, as every reading function's `!` variant does.

## Changing a job

`update_job/3` changes a job that has not finished yet, and returns it as it
now stands:

> Elixir:
>
> ```elixir
> Zizq.update_job(job, MyApp.Zizq, queue: "urgent", priority: 0)
> #=> {:ok, %Zizq.Job{queue: "urgent", priority: 0}}
> ```

Changeable: `:queue`, `:priority`, `:ready_at`, `:retry_limit`, `:backoff` and
`:retention`.

### Absent, `nil`, and a value are three instructions

This is JSON merge patch, so the three cases mean different things:

Given | Means
--- | ---
the option is **omitted** | leave the field as it is
the option is **`nil`** | clear it to the server's default
the option has a **value** | set it

> Elixir:
>
> ```elixir
> # Move it, and leave everything else alone.
> Zizq.update_job(job, MyApp.Zizq, queue: "urgent")
>
> # Retry with the server's default limit, whatever that now is.
> Zizq.update_job(job, MyApp.Zizq, retry_limit: nil)
>
> # Make it ready right now, whatever it was scheduled for.
> Zizq.update_job(job, MyApp.Zizq, ready_at: nil)
> ```

That last one is the useful shape of "run this now": `ready_at: nil` clears
the schedule, which makes the job immediately `:ready`.

`:queue` and `:priority` cannot be `nil` — they have no server default to
clear to — and saying so raises rather than costing a round trip to be told
the same thing:

> Elixir:
>
> ```elixir
> Zizq.update_job(job, MyApp.Zizq, queue: nil)
> ** (ArgumentError) update :queue cannot be nil — it has no server default to
>    clear to. Omit it to leave the job's queue unchanged.
> ```

`:retention` is merged field by field, so `retention: [completed: :timer.hours(1)]`
leaves `:dead` alone. Passing `retention: nil` clears the whole override.

### Only unfinished jobs

A completed or dead job cannot be changed — there is nothing left to affect —
and the server rejects it with `%Zizq.Error{reason: :invalid_request}`. To put
a dead job back to work, enqueue it again.

## Deleting a job

> Elixir:
>
> ```elixir
> Zizq.delete_job(job, MyApp.Zizq)
> #=> :ok
> ```

Unlike failing a job with `kill: true`, which leaves a dead job behind to be
inspected, this removes it. A job the server no longer holds is
`{:error, %Zizq.Error{reason: :not_found}}`.

## Changing or deleting many at once

Both bulk operations select with the same filters and return **how many** they
affected.

### Deleting

> Elixir:
>
> ```elixir
> Zizq.delete_all_jobs([queue: "emails", status: :dead], MyApp.Zizq)
> #=> {:ok, 17}
> ```

Counting first with the same filters is a cheap way to see what would go:

> Elixir:
>
> ```elixir
> filters = [queue: "emails", status: :dead]
>
> {:ok, 17} = Zizq.count_jobs(filters, MyApp.Zizq)
> {:ok, 17} = Zizq.delete_all_jobs(filters, MyApp.Zizq)
> ```

> [!WARNING]
> Filters restrict what is deleted the way a `WHERE` clause does, and are
> optional for the same reason. `Zizq.delete_all_jobs([], client)` empties the
> server — deliberately, but it is worth knowing that an empty filter list is
> not a no-op.

### Updating

`update_all_jobs/2` takes `:where` and `:apply` rather than two positional
lists:

> Elixir:
>
> ```elixir
> Zizq.update_all_jobs(
>   [where: [queue: "emails", status: :scheduled], apply: [ready_at: nil]],
>   MyApp.Zizq
> )
> #=> {:ok, 42}
> ```

`:where` selects with the filters above and is optional; `:apply` says what to
change, with the merge-patch rules of `update_job/3`, and is required.

They are named because both halves are keyword lists with **overlapping
keys** — `queue:` and `priority:` mean something on each side — so transposing
two positional arguments would quietly change the wrong jobs rather than fail.

> Elixir:
>
> ```elixir
> # Drain a queue by moving everything waiting on it.
> Zizq.update_all_jobs(
>   [where: [queue: "old_queue", status: [:ready, :scheduled]], apply: [queue: "new_queue"]],
>   MyApp.Zizq
> )
> ```

Finished jobs cannot be changed, so asking for one is an error rather than a
silent no-op — `status: :completed` or `status: :dead` in `:where` is rejected
before the request is sent:

> Elixir:
>
> ```elixir
> Zizq.update_all_jobs([where: [status: :dead], apply: [priority: 0]], MyApp.Zizq)
> ** (ArgumentError) cannot change jobs with status :dead — a finished job is not
>    editable. Filter by a status that can still run, or delete them.
> ```

### Through a query

`Zizq.Query` has both, so a query you already built can be acted on rather
than restated:

> Elixir:
>
> ```elixir
> query =
>   Zizq.query(MyApp.Zizq)
>   |> Zizq.Query.where(queue: "emails", status: :dead)
>
> Enum.count(query)             # look first
> Zizq.Query.delete_all(query)  # then act
> ```

> Elixir:
>
> ```elixir
> Zizq.query(MyApp.Zizq)
> |> Zizq.Query.where(queue: "emails", status: :scheduled)
> |> Zizq.Query.update_all(ready_at: nil)
> #=> 42
> ```

These raise on failure rather than returning a tuple, matching how enumerating
a query behaves.

### Working in batches

By default both send **one request** and let the server do the work from the
filters, which is what you want for anything of ordinary size.

Give the query a `limit/2` or an `in_pages_of/2` and they switch to working a
page at a time instead, acting on each page by id:

> Elixir:
>
> ```elixir
> Zizq.query(MyApp.Zizq)
> |> Zizq.Query.where(queue: "emails", status: :dead)
> |> Zizq.Query.in_pages_of(1_000)
> |> Zizq.Query.delete_all()
> #=> 4_213_889
> ```

Ten million jobs then become a run of bounded requests rather than one
enormous one. The count returned is the total across every batch either way.

Each page's ids are sent **with** the original filters rather than instead of
them. An id is only a name, so a job that stopped matching between being
listed and being acted on — taken by a worker, say — is left alone.

## Listing queues

> Elixir:
>
> ```elixir
> Zizq.list_queues(MyApp.Zizq)
> #=> {:ok, ["default", "emails", "reports"]}
> ```

Queues are not declared — one exists because a job named it — so this reports
what is there rather than what was configured. A queue that has emptied and
been purged stops being listed.

## Reading a job's failures

The server keeps a record per **failed attempt**, so a job that failed three
times has three:

> Elixir:
>
> ```elixir
> {:ok, page} = Zizq.list_errors(job, MyApp.Zizq)
>
> for error <- page.errors do
>   IO.puts("attempt #{error.attempt}: #{error.message}")
> end
> #=> attempt 1: SMTP timeout
> #=> attempt 2: SMTP timeout
> ```

Each is a `Zizq.ErrorRecord` with `:attempt`, `:message`, `:error_type`,
`:backtrace`, `:dequeued_at` and `:failed_at`. Listings page exactly as job
listings do, through `next_page/2`, and take `:limit` and `:order` the same
way — though the server caps error pages at 200 records rather than 2000.

One attempt can be fetched directly, counting from 1:

> Elixir:
>
> ```elixir
> Zizq.get_error(job, 1, MyApp.Zizq)
> #=> {:ok, %Zizq.ErrorRecord{attempt: 1, message: "SMTP timeout"}}
> ```

> [!NOTE]
> `Zizq.ErrorRecord` is not `Zizq.Error`. The first is a record the *server*
> stored about a job that failed; the second is the exception *this client*
> returns or raises when an API call fails.

### `:attempt` versus a job's `:attempts`

They count different things and differ by one while a job runs. A job's
`:attempts` counts attempts already **finished**, so it is `0` on a first run;
a record's `:attempt` numbers the attempt it belongs to, so the first failure
is `1`:

```
run  handler sees      on failure, records   job ends up with
1    attempts: 0   ->  attempt: 1        ->  attempts: 1
2    attempts: 1   ->  attempt: 2        ->  attempts: 2
```

They align once an attempt is over. So a guard like `when attempts >= 3` first
matches on the fourth run, by which point three records exist, numbered 1 to 3.

Errors live as long as the job does, so a completed job whose retention has
expired takes its failure history with it.

## Erasing everything

> Elixir:
>
> ```elixir
> Zizq.erase_all_data(MyApp.Zizq)
> #=> :ok
> ```

Every job in every queue and every cron schedule, in one request. Intended as
a setup or teardown step in tests and development, where a known-empty server
between scenarios is worth more than the data.

> [!WARNING]
> There is nothing to narrow and nothing to confirm. Do not point this at a
> production server.

## Raising instead of returning

Every function here has a `!` variant that raises `Zizq.Error` rather than
returning `{:error, _}`:

> Elixir:
>
> ```elixir
> job    = Zizq.get_job!(id, MyApp.Zizq)
> count  = Zizq.count_jobs!([queue: "emails"], MyApp.Zizq)
> page   = Zizq.list_jobs!([queue: "emails"], MyApp.Zizq)
> queues = Zizq.list_queues!(MyApp.Zizq)
> ```

Use them where a failure should abort the surrounding work, and the tuple
form where it is a condition to handle. `Zizq.Query` uses the raising forms
throughout, for the reason given above.
