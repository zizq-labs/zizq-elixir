# Concurrency & Rate Limiting

> [!NOTE]
> This feature requires a Zizq [pro license](https://zizq.io/pricing) on the
> server.

Applications enqueue jobs to move expensive work off the request path, but some
of that work may put pressure on systems that will not absorb it. An image
service may cap you at 10,000 requests an hour. A surge in push notifications
may dominate the queue and starve everything else of available workers. Both
are solved by a feature which Zizq calls **budgets**.

A budget is a named pool of *tokens* managed under a *strategy*. Jobs bind to
one or more budgets, each with a *cost* that defaults to `1`, and a job must
debit that cost from every budget it is bound to before it can be dispatched.

Crucially this happens on the server, before a worker ever sees the job.
Workers stay naive: they receive jobs and run them, with no waiting, no
sleeping, and no re-queueing something that should have waited. When a job is
at the front of the queue but cannot yet debit its `cost` because the pool is
depleted, that job is *parked* — it stays in the queue and is dispatched
the moment its budgets allow. The server handles this efficiently. Everything
else that is able to run instantly continues dispatching without interruption.

> Elixir:
>
> ```elixir
> # At most 3 of these can be `:in_flight` at once.
> # Generally defined somewhere in your app startup path.
> Zizq.Budget.new!(
>   key: "stripe",
>   allocation: 3,
>   strategy: :while_in_flight
> )
> |> Zizq.define_budget(MyApp.Zizq)
>
> defmodule MyApp.ChargeCard do
>   use Zizq.JobKind,
>     type: "charge_card",
>     queue: "billing",
>     budgets: [[key: "stripe"]]
>
>   @impl Zizq.JobKind
>   def perform(%{"invoice_id" => id}), do: MyApp.Billing.charge(id)
> end
> ```

That is the whole integration. Nothing in `perform/1` knows about the limit.

> [!NOTE]
> Budgets are a shared resource, and the server caps how many distinct ones can
> exist — `8192` by default, configurable with `--max-budgets`
> (`$ZIZQ_MAX_BUDGETS`) when launching `zizq serve`. That is far more than most
> applications need. A future release will add sub-buckets for dynamically
> allocated scenarios.

## Strategies

Two strategies exist. Both take an `:allocation`, which is the number of tokens
in the pool. A job may bind to several budgets freely mixing both strategies,
in which case *all* of its budgets must be satisfied before it is dispatched.

### `:while_in_flight`

Pure concurrency control: at most `N` of these jobs run (i.e. are `:in_flight`)
at once.

> Elixir:
>
> ```elixir
> Zizq.Budget.new!(
>   key: "image-service",
>   allocation: 20,
>   strategy: :while_in_flight
> )
> |> Zizq.define_budget(MyApp.Zizq)
> ```

Tokens are debited when the job is dispatched and released when it stops
running — on success or on failure. There is no clock involved at all. With an
allocation of `20` you get 20 concurrent jobs at the default cost, or 10 at a
cost of `2`, or any mix that fits:

- `20 × cost=1`
- `10 × cost=2`
- `(5 × cost=2) + (10 × cost=1)`
- `(3 × cost=5) + (2 × cost=2)`

### `:time_based`

A rate limit: at most `N` jobs *dispatched* over a period. It takes a
`:duration` alongside the allocation.

> Elixir:
>
> ```elixir
> Zizq.Budget.new!(
>   key: "image-service",
>   allocation: 10_000,
>   strategy: :time_based,
>   duration: :timer.hours(1)
> )
> |> Zizq.define_budget(MyApp.Zizq)
> ```

> [!IMPORTANT]
> `:duration` is **milliseconds**. `:timer.hours/1`, `:timer.minutes/1` and
> `:timer.seconds/1` keep that readable.

Unlike `:while_in_flight`, tokens are *not* returned when a job finishes. They
return on the cadence the duration sets. So a `:time_based` budget governs how
often work **starts**, and says nothing about how much is running at once —
jobs slower than the duration will overlap, by design.

The server implements this lazily. It does not scan for work that has become
affordable; it knows when the next token is due and sleeps until then, or until
something else wakes it.

#### Implementation note

`:time_based` is a *continuous* (drip) rate limiter — a
[leaky bucket](https://en.wikipedia.org/wiki/Leaky_bucket) — rather than one
that buckets tokens into fixed windows. With 100 tokens over 5 minutes and an
empty pool, you have 20 tokens after a minute, 80 after four, and all 100 after
five. Work spreads out evenly instead of arriving in a spike at each window
boundary and then stalling until the next one.

A full pool is a different matter. 100 tokens available means 100 jobs can go
at once, after which the pace settles to roughly one every three seconds.
That is usually what you want — it absorbs short-lived spikes — but not
always, which is what `:burst` is for.

### `:burst`

`:burst` caps how full the pool may get at any given time.

> Elixir:
>
> ```elixir
> Zizq.Budget.new!(
>   key: "image-service",
>   allocation: 10_000,
>   strategy: :time_based,
>   duration: :timer.hours(1),
>   burst: 500
> )
> |> Zizq.define_budget(MyApp.Zizq)
> ```

At most 500 jobs go at once, then 10,000/hour at a steady pace. A `:burst` of
`1` removes the spike entirely and paces dispatches evenly at all times.

A burst *above* the allocation is meaningful too: `20_000` on a 10,000/hour
budget permits a deliberate spike beyond the rate limit, but only if the budget
went unused long enough to accrue it.

The opening burst only happens when the pool is genuinely full — either nothing
has been dispatched for a whole duration, or the budget is newly created (or
the server was restarted).

`Zizq.Budget.capacity/1` reports what actually applies: the burst where one is
set, and the allocation otherwise.

> [!NOTE]
> Every job's cost must fit inside the capacity, or it could never run. The
> server rejects a binding that cannot fit, and rejects a change to a budget
> that would strand a job already bound to it. With a `:burst` set it is the
> *smaller* number that decides, so a cost well within the allocation may still
> be refused.

## Binding jobs to budgets

A job module declares which budgets it is bound to, and every enqueue carries
that information:

> Elixir:
>
> ```elixir
> defmodule MyApp.SendEmail do
>   use Zizq.JobKind,
>     type: "send_email",
>     queue: "emails",
>     budgets: [[key: "emails", cost: 2]]
>
>   @impl Zizq.JobKind
>   def perform(payload), do: MyApp.Mailer.deliver(payload)
> end
> ```

`use Zizq.JobKind` evaluates its options while the module compiles, so a
malformed binding fails the build rather than the first enqueue.

A single enqueue can override the module's default:

> Elixir:
>
> ```elixir
> MyApp.SendEmail.new(
>   %{"user_id" => 42},
>   budgets: [
>     [key: "emails"],
>     [key: "smtp", cost: 5]
>   ]
> )
> |> Zizq.enqueue(MyApp.Zizq)
> ```

With no budgets a job is unthrottled and dispatches as soon as it reaches the
front of the queue. With several, it must satisfy of them. A job bound to
a `:while_in_flight` limit of 10 and a `:time_based` limit of 1000/hour honours
both: never more than 10 at once, never more than 1000 an hour.

Use `:cost` to make jobs weigh differently against the same pool. A bulk send
costing `10` against an allocation of `100` leaves room for 90 more single
sends.

### Creating a budget as you bind to it

A budget normally exists before anything binds to it. `:create_with` lets one
enqueue do both atomically:

> Elixir:
>
> ```elixir
> defmodule MyApp.SendEmail do
>   use Zizq.JobKind,
>     type: "send_email",
>     queue: "emails",
>     budgets: [
>       [
>         key: "emails",
>         cost: 2,
>         create_with: [
>           allocation: 100,
>           strategy: :time_based,
>           duration: :timer.minutes(1)
>         ]
>       ]
>     ]
> end
> ```

The key comes from the binding, so it is not repeated. If the budget already
exists the policy is _ignored_ and the stored one stays authoritative — an
enqueue will never clobber an existing tuned budget.

## Managing budgets

> Elixir:
>
> ```elixir
> Zizq.list_budgets(MyApp.Zizq)
> Zizq.get_budget("emails", MyApp.Zizq)
> Zizq.define_budget(budget, MyApp.Zizq)
> Zizq.update_budget("emails", MyApp.Zizq, burst: 5)
> Zizq.delete_budget("emails", MyApp.Zizq)
> ```

Bang `!` variants that raise also exist.

`define_budget/3` refuses an existing key with `%Zizq.Error{reason: :conflict}`
and leaves the stored policy alone. Hence it is ok for every process in a
horizontally scaled workload to declare its budgets on boot without
coordination, and those one that lose the race simply treat the conflict as
success.

> Elixir:
>
> ```elixir
> def declare_budgets do
>   case Zizq.define_budget(budget, MyApp.Zizq) do
>     {:ok, budget} -> {:ok, budget}
>     {:error, %Zizq.Error{reason: :conflict}} -> :already_declared
>     {:error, error} -> {:error, error}
>   end
> end
> ```

Pass `replace: true` to overwrite instead. A replace changes the policy, not
the budget's identity, so `:created_at` survives it.

`update_budget/3` is a deep (recursive) merge patch, so it is valid to change
a single field inside the `strategy` without repeating all the others.
`burst: nil` is the one meaningful use of `nil` — it clears the bucket's
ceiling back to the default (its total allocation).

## Changing which budgets jobs are bound to

Bindings are mutable even after jobs are enqueued. This is allows making
adjustments e.g. during an incident response, such as splitting one shared
budget in two, or taking a rate limit off a job that is stuck behind it.

> Elixir:
>
> ```elixir
> Zizq.bind_budget(job, MyApp.Zizq, key: "emails", cost: 2)
> Zizq.rebind_budget(job, MyApp.Zizq, key: "emails")
> Zizq.set_budget_cost(job, MyApp.Zizq, "emails", 5)
> Zizq.unbind_budget(job, MyApp.Zizq, "emails")
> Zizq.unbind_all_budgets(job, MyApp.Zizq)
> Zizq.replace_budgets(job, MyApp.Zizq, [[key: "emails", cost: 2]])
> ```

Each returns the updated job, so its `:budgets` reflect the change without a
second read. `bind_budget/3` conflicts if the job is already bound to that
budget; `rebind_budget/3` replaces the binding whole.

The same operations run over a selection:

> Elixir:
>
> ```elixir
> Zizq.query(MyApp.Zizq)
> |> Zizq.Query.where(queue: "emails")
> |> Zizq.Query.bind_budget(key: "stripe", cost: 2)
> ```

> [!IMPORTANT]
> Only queued jobs (`:scheduled`, `:ready`) can be rebound. An in-flight job
> has already debited its tokens, and jobs in terminal states are always
> immutable. The bulk forms report the ones they could not touch rather than
> skipping them silently:
>
> ```elixir
> %Zizq.BudgetChange{changed: 12, blocked: ["01K9...", "01KA..."]}
> ```
>
> `:blocked` is always in-flight jobs, so it can be handles as a retry list —
> they drain on their own, and the same call afterwards picks them up.
> `Zizq.BudgetChange.complete?/1` is the check for an empty one.

## Finding what is bound to a budget

A budget cannot be deleted while anything remains bound to it. The
`:budgets_key` filter selects exactly what is bound, and works anywhere
jobs are filtered:

> Elixir:
>
> ```elixir
> Zizq.count_jobs([budgets_key: "emails"], MyApp.Zizq)
>
> Zizq.query(MyApp.Zizq)
> |> Zizq.Query.where(budgets_key: "emails")
> |> Zizq.Query.unbind_budget("emails")
>
> Zizq.delete_budget("emails", MyApp.Zizq)
> ```

`Zizq.Job` also reports its bindings:

> Elixir:
>
> ```elixir
> Zizq.get_job!(id, MyApp.Zizq).budgets
> #=> [%Zizq.BudgetBinding{key: "emails", cost: 2}]
> ```

The `:cost` there is the one that applies, and was resolved to the default
where the enqueue didn't specify it. There is no `:create_with` on a read —
that was acted upon at enqueue-time and is not permanently stored as part of
the job.

## Cron entries

A cron entry's job template carries budgets like any other enqueue, so
scheduled work can use the feature in the same way:

> Elixir:
>
> ```elixir
> Zizq.Cron.new("nightly",
>   entries: [
>     [
>       name: "digest",
>       expression: "0 9 * * *",
>       job: MyApp.SendDigest.new(%{}, budgets: [[key: "emails"]])
>     ]
>   ]
> )
> |> Zizq.replace_cron(MyApp.Zizq)
> ```
