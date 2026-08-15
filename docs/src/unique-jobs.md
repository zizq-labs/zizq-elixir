# Unique Jobs

> [!NOTE]
> This feature requires a Zizq [pro license](https://zizq.io/pricing) on the
> server. Without one the server responds 403, which arrives as
> `%Zizq.Error{reason: :forbidden}`.

Zizq can skip a duplicate enqueue of the same logical job while an earlier
one is still around. Two things are used to make the decision: a **unique key**
identifying the job, and a **scope** saying how long that identity holds.

> Elixir:
>
> ```elixir
> defmodule MyApp.SendWelcomeEmail do
>   use Zizq.JobKind,
>     type: "send_welcome_email",
>     unique_key: {:payload, only: [".user_id"]},
>     unique_while: :queued
>
>   @impl Zizq.JobKind
>   def perform(%{"user_id" => id}), do: MyApp.Mailer.welcome(id)
> end
> ```

Enqueue that twice for the same user and the second call succeeds — it just
returns the job that already exists rather than creating a second one.

## Enqueuing a unique job

Nothing changes at the call site:

> Elixir:
>
> ```elixir
> {:ok, first}  = MyApp.SendWelcomeEmail.new(%{"user_id" => 42}) |> Zizq.enqueue(MyApp.Zizq)
> {:ok, second} = MyApp.SendWelcomeEmail.new(%{"user_id" => 42}) |> Zizq.enqueue(MyApp.Zizq)
>
> second.id        == first.id  #=> true
> second.duplicate              #=> true
> first.duplicate               #=> false
> ```

A duplicate is **not an error**. The existing job comes back flagged with
`:duplicate`, so code that does not care can ignore it entirely and code that
does can branch on it.

## Uniqueness scopes

`:unique_while` decides how long the key is held. The default is `:queued`.

Scope | Duplicates skip while the job is
--- | ---
`:queued` | `:scheduled` or `:ready` — until a worker takes it
`:active` | `:scheduled`, `:ready` or `:in_flight` — until it completes
`:exists` | still on the server at all, per its retention policy

`:queued` means that as soon as a worker picks the job up, a new one with the
same key is accepted. That is usually what you want for "coalesce a burst of
requests into one job": while the job waits, further requests are subsumbed by
it; once it starts running, a new request is genuinely new work.

`:active` extends that across execution, so a long-running job cannot have a
second copy start alongside it.

`:exists` is the strongest — the key is held for as long as the server
remembers the job, which is governed by its
[retention policy](./defining-jobs.md#retention-policy). Use it for work that
must happen exactly once ever, and set retention deliberately, since a job
purged after an hour stops blocking duplicates after an hour.

> Elixir:
>
> ```elixir
> use Zizq.JobKind,
>   type: "charge_customer",
>   unique_key: {:payload, only: [".invoice_id"]},
>   unique_while: :exists,
>   retention: [completed: :timer.hours(24 * 30)]
> ```

## Unique keys

The key is a string the server compares. You can supply it directly, or have
it derived from the payload.

### Derived from the payload

`{:payload, only: [...]}` hashes just the named fields, so jobs that agree on
those are the same job whatever else differs:

> Elixir:
>
> ```elixir
> use Zizq.JobKind,
>   type: "send_email",
>   unique_key: {:payload, only: [".user_id", ".template"]}
> ```

With that, these two enqueues are the same job — the timestamp is not part of
the key:

> Elixir:
>
> ```elixir
> MyApp.SendEmail.new(%{"user_id" => 42, "template" => "welcome", "at" => "09:00"})
> MyApp.SendEmail.new(%{"user_id" => 42, "template" => "welcome", "at" => "17:30"})
> ```

`{:payload, except: [...]}` inverts it — everything counts except what you
name, which suits a payload that carries one volatile field:

> Elixir:
>
> ```elixir
> unique_key: {:payload, except: [".requested_at"]}
> ```

And `:payload` on its own hashes the whole thing:

> Elixir:
>
> ```elixir
> unique_key: :payload
> ```

### Paths

Paths are jq-flavoured:

Path | Selects
--- | ---
`"."` | the whole payload
`".user_id"` | a key
`".user.id"` | a nested key
`".items[0]"` | an array element
`~s(.["dotted.key"])` | a key containing a dot

A path that matches nothing is skipped rather than treated as `null`, so a
payload that omits an optional field hashes the same as one that never had it.

Paths are parsed **while the job module compiles**, so a malformed one is a
build failure and no enqueue pays to parse it:

> Command:
>
> ```bash
> $ mix compile
> ** (ArgumentError) a payload path must start with '.', got: "user_id"
> ```

### The type prefix

Derived keys are prefixed with the job type by default:

> Elixir:
>
> ```elixir
> "send_email:1f98104cc5a072ae84731379f5888c48c1886f7d58681e806cc9cca4d601f765"
> ```

Unique keys are global on the server, not scoped per type, so without the
prefix a `send_email` and a `send_sms` carrying the same payload would collide
— and the second would silently dedupe against the first.

Turn it off deliberately when that is what you want, such as a push
notification and an email that represent one logical event:

> Elixir:
>
> ```elixir
> unique_key: {:payload, only: [".event_id"], prefix: false}
> ```

### A literal key

If you already have an identifier, you can use it directly:

> Elixir:
>
> ```elixir
> Zizq.enqueue(
>   [type: "charge_customer", unique_key: "invoice:#{invoice.id}", unique_while: :exists],
>   MyApp.Zizq
> )
> ```

This is also a reasonable way to deduplicate across job types, since you
control the string entirely.

### Overriding per enqueue

A module's key can be replaced just for one enqueue like any other option:

> Elixir:
>
> ```elixir
> MyApp.SendEmail.new(%{"user_id" => 42}, unique_key: "manual-override")
> |> Zizq.enqueue(MyApp.Zizq)
> ```

## Without a job module

Every form works on a plain enqueue too:

> Elixir:
>
> ```elixir
> Zizq.enqueue(
>   [
>     type: "send_email",
>     payload: %{"user_id" => 42, "template" => "welcome"},
>     unique_key: {:payload, only: [".user_id", ".template"]},
>     unique_while: :queued
>   ],
>   MyApp.Zizq
> )
> ```

The only difference is when the paths are parsed: once at compile time for a
job module, once per enqueue here.

## How the key is computed

The payload is round-tripped through JSON — collapsing structs, atom keys and
`DateTime`s into what the server actually stores — then streamed into SHA-256
as canonical JSON, with object keys sorted and framing markers between values.

**Key order does not matter, but structure does.** `%{"a" => 1, "b" => 2}` and
`%{"b" => 2, "a" => 1}` hash the same; `[1, 2]` and `[12]` do not.

`Zizq.PayloadHasher` is the module that does this, if you want to compute a
key yourself.

## Incompatibility with batching

A job cannot be both unique and [batched](./batched-jobs.md) — the server
rejects the combination, and so does this client, before any request is made:

> Elixir:
>
> ```elixir
> Zizq.enqueue([type: "a", unique_key: "k", batch: [limit: 10]], MyApp.Zizq)
> ** (ArgumentError) enqueue :unique_key and :batch cannot be combined
> ```

The two answer different questions — "is this job already queued?" versus
"can this fold into a job already queued?" — and applying both to one enqueue
has no coherent meaning.
