# Introduction

Zizq is a simple single-binary persistent job queue server with clients in
various programming languages. All official Zizq clients are **MIT licensed**.

This documentation covers using Zizq from Elixir with the official Zizq Elixir
client, published on [Hex](https://hex.pm/packages/zizq) as the
[`zizq`](https://hex.pm/packages/zizq) package.

The Elixir client is built on [Finch](https://github.com/sneako/finch) and
[Mint](https://github.com/elixir-mint/mint), using HTTP/2 over cleartext for
request and response traffic so many calls share one connection. A worker
runs each job in its own supervised task, so a job that crashes cannot take
the worker down with it.

> [!NOTE]
> If you have not yet installed the Zizq server, follow the
> [Getting Started](/docs/getting-started/) guide first.

## Issues & Source

All client source code is
[available on GitHub](https://github.com/zizq-labs/zizq-elixir). Issues can be
raised on the [issue tracker](https://github.com/zizq-labs/zizq-elixir/issues).

## High-Level Structure

The Elixir client has three core pieces:

1. A **client**, added to your supervision tree as `{Zizq, name: MyApp.Zizq,
   url: ...}`. It owns the connection pool and is referred to everywhere else
   by its name. Several can run side by side under different names.
2. **`Zizq.JobKind`** — a `use`-able module that declares a kind of job: its
   name on the server, the enqueue options it defaults to, and what running it
   does. Job modules are optional; a plain map or keyword list can be enqueued
   just the same.
3. **`Zizq.Worker`** — a supervised process group that streams jobs from the
   server, runs each in its own task, batches acknowledgements, and drains
   cleanly on shutdown. A `Zizq.Router` dispatches several kinds of job
   through one worker, by type.

Everything else — querying, cron, bulk changes — is a function on `Zizq` that
takes the client's name.

## Example

A minimal producer and consumer look like this:

> Elixir:
>
> ```elixir
> defmodule MyApp.SendEmail do
>   use Zizq.JobKind, type: "send_email", queue: "emails"
>
>   @impl Zizq.JobKind
>   def perform(%{"to" => to}) do
>     MyApp.Mailer.deliver(to)
>   end
> end
>
> # In your supervision tree — the client, and a worker to run jobs.
> children = [
>   {Zizq, name: MyApp.Zizq, url: "http://127.0.0.1:7890"},
>   {Zizq.Worker,
>    client: MyApp.Zizq,
>    queues: ["emails"],
>    concurrency: 25,
>    handler: Zizq.Router.new([MyApp.SendEmail])}
> ]
>
> # Anywhere in your application — enqueue a job.
> MyApp.SendEmail.new(%{"to" => "alice@example.com"})
> |> Zizq.enqueue(MyApp.Zizq)
> ```

Producers and consumers are separate. An application can enqueue without
running a worker, run a worker without enqueuing, or do both — and the job it
enqueues may be picked up by a worker written in Ruby, Node or Rust, since a
job's `type` is a plain string agreed across languages rather than an Elixir
module name.

## Conventions

Two things hold throughout the Elixir client and are worth knowing up front.

**Durations are integer milliseconds.** `:timer.seconds/1`, `:timer.minutes/1`
and `:timer.hours/1` keep call sites readable and are evaluated at compile
time, so `retention: [completed: :timer.hours(24)]` costs nothing at runtime.

**Payloads are string-keyed.** Whatever you enqueue is JSON or MessagePack on
the wire, so a handler always receives string keys — `%{"user_id" => 42}`,
never `%{user_id: 42}`. Writing handlers to match on string keys means they
behave the same in tests as in production.

The rest of this guide works through each piece in turn.
