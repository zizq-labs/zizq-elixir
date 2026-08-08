# Changelog

## 0.6.0-alpha.2

First release with a usable API. Jobs can be enqueued; consuming them
cannot — the take stream and worker are still to come, as are the
query, cron and bulk endpoints.

### Added

- **`Zizq` client supervisor.** Add one to your application's
  supervision tree and refer to it by name:

      children = [
        {Zizq, name: MyApp.Zizq, url: "http://localhost:7890"}
      ]

  Several named clients can run side by side. API functions are
  stateless — they resolve configuration by name and issue the request
  directly, so no Zizq process sits in the request path. Options are
  validated at startup, so a malformed URL or unknown format fails at
  boot rather than on the first request.

- **`Zizq.enqueue/2` and `Zizq.enqueue!/2`.** Accepts a keyword list,
  a map, or a `Zizq.Enqueue` struct. Only `:type` is required;
  `:queue` defaults to `"default"`, and anything left unset is omitted
  from the request so the server's own defaults apply and keep
  tracking its configuration. Unknown keys are rejected rather than
  ignored, so a typo cannot quietly enqueue the wrong job.

- **`Zizq.Job`.** The job record the server returns. Timestamps are
  `DateTime` in UTC; status is an atom (`:ready`, `:in_flight`, and so
  on). A status an older client does not recognise is preserved as a
  string rather than raising.

- **`Zizq.Backoff`, `Zizq.Retention`, `Zizq.BatchConfig`.** Per-job
  policy overrides, accepted as keyword lists or structs. Durations
  are integer milliseconds throughout, so `:timer.seconds/1` and
  friends can be used directly.

- **`Zizq.Codec` behaviour, with `Zizq.Codec.JSON` and
  `Zizq.Codec.MessagePack`.** MessagePack is the default. The two are
  interchangeable on every endpoint, so a producer and a consumer need
  not agree on a format, or even be written in the same language.
  Select with `format: :json`.

- **`Zizq.Error`.** One error type for every failure, carrying a
  `:reason` atom, the HTTP status and body where there was one, and
  the underlying exception behind transport and codec failures.
  `Zizq.Error.retryable?/1` says whether retrying could plausibly
  succeed.

- **`Zizq.server_version/1`.** Reports the server's version; the
  cheapest way to confirm a connection works end to end.

### Notes

- Request and response traffic uses HTTP/2 over cleartext (h2c) with
  connection multiplexing. The forthcoming take stream will use
  HTTP/1.1 instead, where HTTP/2 framing overhead makes it slower.
- Requires Elixir 1.18 or later and Erlang/OTP 27 or later.
- Pre-release versions are opt-in: a requirement must name one (for
  example `~> 0.6.0-alpha`) to resolve them.

## 0.6.0-alpha.1

Package skeleton only. No client API yet. Published purely to exercise
the release pipeline.
