# Installation & Setup

> [!NOTE]
> If you have not yet installed the Zizq server, follow the
> [Getting Started](/docs/getting-started/) guide first.

The official Zizq Elixir client is the [`zizq`](https://hex.pm/packages/zizq)
package. Add it to your dependencies:

> mix.exs:
>
> ```elixir
> def deps do
>   [
>     {:zizq, "~> 0.6.1"}
>   ]
> end
> ```

> Command:
>
> ```bash
> $ mix deps.get
> ```

The client requires **Elixir 1.18** or later and **Erlang/OTP 27** or later.
Elixir 1.18 is the floor because the client uses the built-in `JSON` module
rather than carrying a JSON dependency of its own.

## Versioning

Zizq client libraries are versioned with the same version numbers as the Zizq
server, which follows the SemVer structure `[MAJOR].[MINOR].[PATCH]`.

Whenever a new version of the server is released, client libraries with the
same major and minor version numbers are also released. Provided the major
versions match, the client should generally have an equal or lower minor
version than the server. Patch numbers are insignificant.

The client should never exceed the server's major and minor version, because
it likely expects functionality that does not exist on the server.

Server Version | Client Version | Supported
---------------|----------------|----------
0.1.0          | 0.1.0          | ✅
0.5.12         | 0.3.7          | ✅
1.0.1          | 0.12.2         | ❌
0.5.12         | 0.5.23         | ✅
0.5.12         | 0.6.0          | ❌

## Configuration

The client is a supervised process. Add it to your application's supervision
tree, and refer to it everywhere else by its `:name`:

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
>     Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
>   end
> end
> ```

Every other function takes that name:

> Elixir:
>
> ```elixir
> Zizq.enqueue([type: "send_email", payload: %{"to" => "alice@example.com"}], MyApp.Zizq)
> ```

There is no global configuration and no implicit default client. Naming the
client at each call site means several can run side by side — pointing at
different servers, or using different formats — without ambiguity:

> Elixir:
>
> ```elixir
> children = [
>   {Zizq, name: MyApp.Zizq, url: "http://127.0.0.1:7890"},
>   {Zizq, name: MyApp.Analytics, url: "http://analytics.internal:7890"}
> ]
> ```

> [!TIP]
> Reading the URL from configuration keeps environments apart:
>
> ```elixir
> {Zizq, name: MyApp.Zizq, url: Application.fetch_env!(:my_app, :zizq_url)}
> ```

### Options

- **`:name`** (required) — an atom naming this client. Also names the
  supervisor, and is the handle passed to every other function.

- **`:url`** (required) — the base URL of the Zizq server, as a string or a
  `URI`. A path is allowed and is treated as a prefix, for servers behind a
  reverse proxy.

- **`:format`** — `:msgpack` (the default), `:json`, or a module implementing
  the `Zizq.Codec` behaviour. Both built-in formats are interchangeable on
  every endpoint, so a producer and a consumer need not agree on one, or even
  be written in the same language.

- **`:pool_count`** — how many HTTP/2 connections to hold. Each is fully
  multiplexed, so one is usually enough; raise it only if a single connection
  becomes a bottleneck. Defaults to `1`.

- **`:connect_timeout`** — milliseconds to wait for a connection to be
  established. Defaults to `5_000`.

- **`:receive_timeout`** — milliseconds to wait for a response. Does not apply
  to the streaming endpoint a worker uses. Defaults to `15_000`.

- **`:stream_idle_timeout`** — milliseconds a worker's stream may go without
  any data before it is treated as dead and reconnected. The server sends
  heartbeats on an otherwise idle stream precisely so this can be detected, so
  the timeout only has to exceed that interval. Defaults to `30_000`, ten
  times the server's own default heartbeat of three seconds.

- **`:tls`** — certificates for connecting over HTTPS. See
  [TLS and mutual TLS](#tls-and-mutual-tls) below.

> [!WARNING]
> If you run the server with a longer heartbeat interval, raise
> `:stream_idle_timeout` to match. A timeout shorter than the heartbeat would
> reconnect a perfectly healthy connection on a loop.

Options are validated when the client starts, so a malformed URL or an unknown
format fails at boot rather than on the first request.

## TLS and mutual TLS

An `https://` URL needs no configuration. Connections verify against the
system's trust store, with `verify_peer` on:

> Elixir:
>
> ```elixir
> {Zizq, name: MyApp.Zizq, url: "https://zizq.example.com"}
> ```

`:tls` is for the two cases that store cannot cover: a server whose
certificate was issued by a **private CA**, and a server that demands a
**client certificate**.

> Elixir:
>
> ```elixir
> {Zizq,
>  name: MyApp.Zizq,
>  url: "https://zizq.internal:7890",
>  tls: [
>    ca: "/etc/zizq/ca.pem",
>    client_cert: "/etc/zizq/client.pem",
>    client_key: "/etc/zizq/client-key.pem"
>  ]}
> ```

- **`:ca`** — verify the server against this authority instead of the system
  trust store. Use it for a certificate the system would not otherwise trust.
- **`:client_cert`** and **`:client_key`** — the identity to present for
  mutual TLS. Both are needed; either alone is rejected at boot, because a
  certificate with no key presents nothing and a key with no certificate has
  nothing to present.

> [!NOTE]
> Mutual TLS requires a Zizq [pro license](https://zizq.io/pricing) on the
> server.

### PEM contents or a path

Every value may be the PEM text itself or a path to a file holding it, told
apart by the `-----BEGIN` header. That suits both a mounted secret and one
read from the environment:

> Elixir:
>
> ```elixir
> tls: [
>   ca: System.fetch_env!("ZIZQ_CA_PEM"),
>   client_cert: System.fetch_env!("ZIZQ_CLIENT_CERT_PEM"),
>   client_key: System.fetch_env!("ZIZQ_CLIENT_KEY_PEM")
> ]
> ```

A `:ca` holding several certificates is used whole, so an intermediate chain
in one file works. The same is true of `:client_cert`, for a leaf plus its
chain.

An **encrypted** private key cannot be given as PEM text, since there is
nowhere to put the passphrase. Pass a path instead.

### Both connections are covered

A client opens two kinds of connection: the pooled HTTP/2 one that carries
requests, and the separate HTTP/1.1 one a worker's stream owns. `:tls` applies
to both, so a worker is not quietly exempt from the verification the rest of
the client does.

Configuration is checked at boot — a missing file, a certificate without its
key, or `:tls` on an `http://` URL fails when the client starts, rather than
as a handshake error on the first request, where the cause is several layers
away from the mistake.

## Checking the connection

`Zizq.server_version/1` is the cheapest call the server offers, and proves the
connection works end to end:

> Elixir:
>
> ```elixir
> Zizq.server_version(MyApp.Zizq)
> #=> {:ok, "0.6.1"}
> ```

If the client is not running you will get an `ArgumentError`, rather than a
connection error. The name is resolved before any request is made.
