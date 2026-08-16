# Uptime Monitor (Elixir example)

Watches URLs for uptime, follows sitemaps, reports transitions to a
webhook, and re-checks on a cron schedule. Touches most of Zizq's
surface: enqueue, bulk enqueue, cron, retries and backoff.

Where the [audit_log](../audit_log/) example is deliberately
low-level, this one is a **Phoenix** app — LiveView, PubSub, Ecto —
so the two together show Zizq in both shapes.

* **Phoenix + LiveView** for the dashboard. Rows update as probes
  land, with no polling: the worker records a check, the context
  broadcasts, and connected browsers re-render.
* **Ecto + SQLite** for storage.
* **`Zizq.Router`** with four job types under `lib/uptime_monitor/jobs/`.
* **`Zizq.Worker`** supervised alongside the endpoint, drainable
  separately so web and worker can scale apart.

## Prerequisites

* Elixir **1.18 or newer**.
* A running Zizq server on `ZIZQ_URL` (default
  `http://127.0.0.1:7890`).
* A **Pro licence** on the server for the periodic sweep, which uses
  cron. Without one the app still works — URLs submitted by hand are
  checked immediately — and registration logs a warning rather than
  failing to boot.

## First-time setup

```sh
mix setup
```

## Running

```sh
mix phx.server
```

Then open <http://localhost:4000> and submit a URL. Give it a sitemap
and it will find the pages listed inside.

To split the roles, as a real deployment would:

```sh
START_WORKER=0 mix phx.server   # web only
```

It binds to loopback by default. To reach it from another machine:

```sh
BIND=0.0.0.0 mix phx.server
```

> The dashboard has **no authentication**, and anyone who can reach it
> can add or remove monitored URLs. Loopback is the default
> deliberately.

## Job types

| Type | Trigger | What it does |
| --- | --- | --- |
| `uptime_monitor.check_url` | Form submission, cron sweep | Probes one URL, records a check, fires the follow-ups below on a transition |
| `uptime_monitor.discover_sitemap_urls` | A probe that looked like a sitemap | Re-fetches it, reconciles the URLs it lists, bulk-enqueues checks |
| `uptime_monitor.notify_webhook` | A status transition | POSTs the event to `WEBHOOK_URL`; retries on 5xx and network errors |
| `uptime_monitor.schedule_checks` | Cron, every 5s | Bulk-enqueues a check for every enabled URL whose last check is stale |

The cron fires far more often than URLs are actually checked. It is a
heartbeat; `ScheduleChecks` decides what is due, against a one-minute
staleness window. Moving the check interval is a code change, not a
change to a schedule installed on a server.

## What counts as a transition

Only changes are announced, not every probe:

| Previous | Now | Announced? |
| --- | --- | --- |
| same | same | no — nothing happened |
| never checked | up | no — a first success is not news |
| never checked | down | **yes** — an outage should not wait for a second sample |
| up | down | yes (and the reverse) |

## Sitemaps

A probe whose response is XML rooted at `<urlset>` or `<sitemapindex>`
is flagged, and a discovery job re-fetches and parses it.

* URLs listed but not known → created.
* URLs known but no longer listed → **disabled, not deleted**, so the
  checks recorded against them survive.
* URLs that reappear → re-enabled.

A `<sitemapindex>` lists other sitemaps rather than pages. Those
become monitored URLs in their own right, and because probing one
flags it as a sitemap in turn, nested sitemaps are followed with no
special case.

A sitemap that fails to fetch or parse leaves its children exactly as
they were — reading a truncated download as "this sitemap is now
empty" would disable every URL in it.

## Audit events

The app enqueues `audit.create` jobs into the audit queue for the
[audit_log](../audit_log/) example to consume. It shares no code with
it — just a job type, a queue name, and a payload shape.

| Event | When |
| --- | --- |
| `url.added` | A URL is submitted from the dashboard |
| `url.status.changed` | A probe records a different status than the last |
| `sitemap.scanned` | A sitemap has been re-fetched and reconciled |

Run both apps side by side to watch events land in the audit feed.
Point `AUDIT_QUEUE` at a queue nothing consumes to turn auditing off.

## Tests

```sh
mix test
```

Handlers run through `Zizq.Testing.perform_job/3` and outbound HTTP
goes to a `Req.Test` stub, so the suite needs neither a Zizq server
nor a network. A request with no stub registered fails loudly rather
than escaping to the internet.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `ZIZQ_URL` | `http://127.0.0.1:7890` | Where the Zizq server is |
| `ZIZQ_WORKER_CONCURRENCY` | `25` | Jobs run at once |
| `WEBHOOK_URL` | unset | Where transitions are POSTed. Unset means they are recorded but not sent |
| `AUDIT_QUEUE` | `audit` | Queue audit events go to |
| `AUDIT_SOURCE` | `uptime_monitor` | Name this app is recorded under |
| `START_WORKER` | `1` | `0` to run web-only |
| `PORT` | `4000` | Web port (Phoenix default) |
| `BIND` | `127.0.0.1` | Web bind address. `0.0.0.0` to accept connections from other machines |
