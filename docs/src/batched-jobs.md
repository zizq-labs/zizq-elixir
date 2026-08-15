# Batched Jobs

> [!NOTE]
> This feature requires a Zizq [pro license](https://zizq.io/pricing) on the
> server. Without one the server responds 403, which arrives as
> `%Zizq.Error{reason: :forbidden}`.

Batching folds many enqueues into **one** job. Rather than a hundred jobs each
sending one notification, one job accumulates a hundred device ids and sends
them together.

> Elixir:
>
> ```elixir
> defmodule MyApp.PushBatch do
>   use Zizq.JobKind,
>     type: "push",
>     queue: "push",
>     batch: [limit: 100, path: ".device_ids"]
>
>   @impl Zizq.JobKind
>   def perform(%{"device_ids" => ids}), do: MyApp.Push.deliver(ids)
> end
> ```

Each enqueue carries only its own contribution:

> Elixir:
>
> ```elixir
> MyApp.PushBatch.new(%{"device_ids" => [id], "platform" => "apple"})
> |> Zizq.enqueue(MyApp.Zizq)
> ```

The server merges it into the job already waiting, until that job holds 100
device ids, or the job is picked up by a worker, at which point the batch is
sealed and the next enqueue starts a fresh one.

## What you configure

Two options are usually all you need:

- **`:limit`** — the maximum combined length at `:path` before the batch is
  sealed and a new one starts.
- **`:path`** — a jq path to the value that accumulates. Defaults to `"."`,
  meaning the whole payload is the batch and is assumed to be a list.

> Elixir:
>
> ```elixir
> # Accumulate at a field.
> batch: [limit: 100, path: ".device_ids"]
>
> # The whole payload is a list of events.
> batch: [limit: 1_000]
> ```

Two more options shape how entries are merged:

- **`:dedup`** — fold through jq's `unique`, so repeated entries collapse.
- **`:sorted`** — fold through `sort`. `unique` also sorts, so `:dedup`
  subsumes this.

> Elixir:
>
> ```elixir
> batch: [limit: 100, path: ".device_ids", dedup: true]
> ```

## The batch key

The key decides *which* batch an enqueue joins. By default it is derived by
hashing everything in the payload **except** the batch path.

That default is what makes the common case need no key at all. In the push
example, `platform` decides the batch and `device_ids` accumulates into it:

> Elixir:
>
> ```elixir
> # These two fold together — same platform.
> MyApp.PushBatch.new(%{"device_ids" => ["a"], "platform" => "apple"})
> MyApp.PushBatch.new(%{"device_ids" => ["b"], "platform" => "apple"})
>
> # This one starts its own batch — different platform.
> MyApp.PushBatch.new(%{"device_ids" => ["c"], "platform" => "google"})
> ```

In other words: enqueues alike in every respect *but* what they contribute
belong in the same batch. That is almost always the rule you would have
written by hand.

> [!NOTE]
> With `path: "."` there is nothing left to tell batches apart, so every job
> of that type shares one batch. That is usually the intent for a firehose of
> events, for example.

### Overriding the key

Supply a string when you want to name the batch yourself:

> Elixir:
>
> ```elixir
> batch: [limit: 100, path: ".device_ids", key: "push:apple"]
> ```

Or a different derivation, when only part of the payload should decide it:

> Elixir:
>
> ```elixir
> batch: [limit: 100, path: ".events", key: {:payload, only: [".tenant_id"]}]
> ```

Keys take the same forms unique keys do — see
[Unique Keys](./unique-jobs.md#unique-keys).

## What the server does with it

`:limit` and `:path` are not sent as such. The client turns them into the two
jq expressions the server actually evaluates:

> Generated:
>
> ```
> when: (($existing | .device_ids) + ($new | .device_ids)) | length <= 100
> fold: $existing | .device_ids += ($new | .device_ids)
> ```

`when` decides whether this enqueue folds into the waiting batch or seals it;
`fold` produces the merged payload when it does. Both run with `$existing`
bound to the batch's current payload and `$new` to the incoming one.

You will get the same strings from the Ruby, Node and Rust clients — the
templates are identical across all clients.

### Writing the expressions yourself

For a fold the templates do not cover — counting rather than appending, or
merging into a map — give `:key`, `:when` and `:fold` directly:

> Elixir:
>
> ```elixir
> batch: [
>   key: "digest:daily",
>   when: "$existing.count < 100",
>   fold: "$existing | .count += 1 | .ids += $new.ids"
> ]
> ```

`:limit` and `:path` cannot be mixed with them, since they would be generating
the same two fields:

> Elixir:
>
> ```elixir
> batch: [limit: 10, path: ".ids", when: "true"]
> ** (ArgumentError) batch :when is generated from :limit and :path; give either
>    :limit and :path, or :key, :when and :fold, not both
> ```

## Enqueuing into a batch

Nothing changes at the call site. What comes back is the batch job — the one
that already existed, if this enqueue folded into it:

> Elixir:
>
> ```elixir
> {:ok, first}  = MyApp.PushBatch.new(%{"device_ids" => ["a"]}) |> Zizq.enqueue(MyApp.Zizq)
> {:ok, second} = MyApp.PushBatch.new(%{"device_ids" => ["b"]}) |> Zizq.enqueue(MyApp.Zizq)
>
> second.id     == first.id  #=> true
> second.folded              #=> true
> first.folded               #=> false
> ```

A folded enqueue is a success, not an error. Read the merged payload back with
`Zizq.get_job/2`:

> Elixir:
>
> ```elixir
> Zizq.get_job!(first.id, MyApp.Zizq).payload
> #=> %{"device_ids" => ["a", "b"], "platform" => "apple"}
> ```

## The first enqueue's configuration wins

A batch's `when` and `fold` are fixed by the enqueue that **created** it.
Later enqueues joining that batch contribute their payload, not their
configuration.

This matters when deploying a code change: if you change a batch's `:limit`
and restart, batches already waiting keep the old limit until they seal. This
is not a bug, and reading a job back shows which expressions are actually in
force:

> Elixir:
>
> ```elixir
> job = Zizq.get_job!(id, MyApp.Zizq)
> job.batch.when  #=> the expression governing this batch
> ```

## Without a job module

As with everything else, a plain enqueue works:

> Elixir:
>
> ```elixir
> Zizq.enqueue(
>   [
>     type: "push",
>     queue: "push",
>     payload: %{"device_ids" => [id], "platform" => "apple"},
>     batch: [limit: 100, path: ".device_ids"]
>   ],
>   MyApp.Zizq
> )
> ```

## Validation

Malformed configuration is caught before any request:

> Elixir:
>
> ```elixir
> batch: [limit: 0, path: ".ids"]
> ** (ArgumentError) batch :limit must be a positive integer, got 0
>
> batch: [limit: 10, path: "ids"]
> ** (ArgumentError) a payload path must start with '.', got: "ids"
> ```

The path is parsed for its errors rather than its result, so a malformed one
never reaches the server as a jq expression.

### What the server checks

The server validates too, and it checks something the client cannot: it
dry-runs both expressions with the incoming payload bound as **both**
`$existing` and `$new`, before the job is stored. That catches the shape
errors that only appear against real data — indexing a field on a value that
is not an object, a `fold` that yields no output or several — and comes back
as `%Zizq.Error{reason: :invalid_request}` rather than a job that fails later.

Between them, the two checks catch malformed paths and expressions that cannot
run. **Neither catches a path that is merely wrong.** jq returns `null` for a
missing key rather than erroring, and `null` propagates:

> Generated, for `path: ".devise_ids"` — a typo for `.device_ids`:
>
> ```
> when: (($existing | .devise_ids) + ($new | .devise_ids)) | length <= 100
> fold: $existing | .devise_ids += ($new | .devise_ids)
> ```

Both run without error. `null + null` is `null`, whose `length` is `0`, so
`when` is true for ever and the batch never reaches its limit — while `fold`
writes a `devise_ids` key of `null` and quietly drops every contribution after
the first.

> [!TIP]
> Read one back after the first enqueue. `Zizq.get_job!(id, client).payload`
> showing a `null` key you did not put there, or an accumulating field that is
> not accumulating, is this mistake.

## Incompatibility with uniqueness

A job cannot be both batched and [unique](./unique-jobs.md). The server
rejects the combination and so does this client, at the call site that got it
wrong.
