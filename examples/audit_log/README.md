# Audit Log (Elixir example)

A central audit-log sink. Other systems enqueue `audit.create` jobs to
its queue; this app drains them, stores them, and shows them in a
paginated feed.

Deliberately low-level: the point is the cross-language,
producer-decoupled shape — any service in any language can drop an
event in this queue without sharing code with the audit app.

* **Plug + Bandit** for the (read-only) web feed. No framework, so the
  Zizq integration is the visible part of the app rather than one file
  inside a generated skeleton.
* **Ecto + SQLite** for storage.
* **`Zizq.Router`** as the dispatcher — one route, `audit.create`.
* **`Zizq.Worker`** supervised alongside the web endpoint. Both are
  roles that can be switched off independently, so this runs as one
  node or as two.

## Prerequisites

* Elixir **1.18 or newer**.
* A running Zizq server on `ZIZQ_URL` (default
  `http://127.0.0.1:7890`).

## First-time setup

```sh
mix setup
```

Fetches dependencies, creates the database and runs migrations.

## Running

```sh
mix run --no-halt
```

Serves the feed at <http://127.0.0.1:3000> and drains the `audit`
queue in the same node.

To run the two roles as separate processes, which is what a real
deployment would do so they scale apart:

```sh
START_WORKER=0 mix run --no-halt   # web only
START_WEB=0 mix run --no-halt      # worker only
```

It binds to loopback by default. To reach it from another machine — a
container, a VM, or a phone on the same network:

```sh
BIND=0.0.0.0 PORT=3000 mix run --no-halt
```

> The feed is read-only but has **no authentication**, so anyone who
> can reach the port can read every audit event. Loopback is the
> default deliberately.

## Emitting an event

The audit app is a *consumer* — it produces nothing. The quickest way
to see something on the feed is `mix simulate`, which enqueues
fake-but-plausible events drawn from a small catalogue of source
systems (billing, auth, admin console, CRM):

```sh
mix simulate            # one event
mix simulate 50         # fifty, in a single request
```

To stream events at irregular intervals:

```sh
while true; do mix simulate; sleep $((RANDOM % 3 + 1)); done
```

`mix simulate` is just a producer. It starts a Zizq client of its own
and never touches the repo, the schema or the job module — the only
things it shares with the audit app are the queue name and the shape
of the payload.

Nothing about it is Elixir-specific either. This is the same event,
enqueued with `curl`:

```sh
curl -X POST http://127.0.0.1:7890/jobs \
  -H 'content-type: application/json' \
  -d '{
    "type": "audit.create",
    "queue": "audit",
    "payload": {
      "occurred_at": "2026-08-15T10:15:00Z",
      "source": "billing_api",
      "event_type": "invoice.refunded",
      "actor": "chris@example.com",
      "resource": "invoice:4821",
      "text": "Refunded $24.00",
      "data": {"amount_cents": 2400}
    }
  }'
```

The router matches on `"audit.create"`, stores the row, and it appears
in the feed.

## The payload contract

This is everything a producer needs to agree to. Three fields are
required; the rest are optional and the sink does not interpret them.

| Field | Required | Notes |
| --- | --- | --- |
| `occurred_at` | yes | **ISO8601.** When it happened at the source, which is not when it was stored |
| `source` | yes | The producing system, e.g. `"uptime_monitor"` |
| `event_type` | yes | Dot-namespaced, e.g. `"url.status.changed"`. Stored, never switched on |
| `actor` | no | Who did it — a user, or `"system"` |
| `ip` | no | Source IP |
| `resource` | no | What it happened to, e.g. `"monitored_url:42"` |
| `text` | no | Human-readable summary |
| `data` | no | A JSON object of anything else |

A payload missing a required field, or carrying a timestamp that is
not ISO8601, is **cancelled rather than retried** — it will be just as
wrong on the next attempt, so the job dies immediately with a message
naming the field.

## Tests

```sh
mix test
```

Handlers are exercised through `Zizq.Testing.perform_job/3`, so the
suite needs neither a Zizq server nor a network.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `ZIZQ_URL` | `http://127.0.0.1:7890` | Where the Zizq server is |
| `ZIZQ_WORKER_CONCURRENCY` | `25` | Jobs run at once |
| `PORT` | `3000` | Web port |
| `BIND` | `127.0.0.1` | Web bind address. `0.0.0.0` to accept connections from other machines |
| `DATABASE_PATH` | `storage/dev.sqlite3` | SQLite file |
| `START_WEB` | `1` | `0` to run worker-only |
| `START_WORKER` | `1` | `0` to run web-only |
| `AUDIT_QUEUE` | `audit` | Queue `mix simulate` writes to |
