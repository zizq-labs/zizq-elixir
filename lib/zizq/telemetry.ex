# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Telemetry do
  @moduledoc """
  The `:telemetry` events this client emits.

  Attach to them with `:telemetry.attach/4` or `attach_many/4`, or
  point `Telemetry.Metrics` at them — nothing here needs configuring,
  and there is no cost beyond the emit when nothing is attached.

      :telemetry.attach_many(
        "zizq-logger",
        [[:zizq, :job, :stop], [:zizq, :job, :exception]],
        &MyApp.Telemetry.handle/4,
        nil
      )

  Events come in two shapes. Spans emit `:start`, then exactly one of
  `:stop` or `:exception`, and carry `:duration` in native units.
  Single events emit once, with `:system_time`.

  ## `[:zizq, :job, :start | :stop | :exception]`

  A job running in a worker, one span per job, emitted in the task
  the job runs in.

  Metadata on every event:

    * `:worker` — the worker's name
    * `:id`, `:type`, `:queue` — from the job
    * `:attempts` — attempts already finished, so `0` on a first run

  `:stop` adds `:outcome`, which is what the handler's return value
  was understood as:

  | `:outcome` | Handler returned |
  | --- | --- |
  | `:ok` | `:ok` or `{:ok, term}` |
  | `:error` | `{:error, reason}` |
  | `:cancel` | `{:cancel, reason}` |
  | `:snooze` | `{:snooze, _}` |
  | `:unknown` | anything else — acknowledged, and warned about |

  A handler that raises, exits or is killed produces `:exception`
  rather than `:stop`, with `:kind`, `:reason` and `:stacktrace`.
  Between them the two cover every job, so counting `:stop` alone
  undercounts.

  ## `[:zizq, :enqueue, :start | :stop | :exception]`

  One span per call, not per job — a bulk enqueue of a thousand jobs
  is one request and one span.

  Metadata on every event:

    * `:client` — the client's name
    * `:count` — jobs in the request
    * `:type`, `:queue` — from the job — or `nil` for a bulk enqueue,
      whose jobs need not agree on either

  `:stop` adds `:outcome`, `:ok` or `:error`, and `:error` carries the
  `Zizq.Error` when it was the latter. A rejected enqueue returns an
  error rather than raising, so it is a `:stop`, not an `:exception` —
  count both `:exception` and `outcome: :error` to catch every failure.

  ## `[:zizq, :stream, :connect]`

  The take stream got its `200`, so the server has accepted the
  request and jobs will follow. Metadata: `:client` and `:url`.

  ## `[:zizq, :stream, :disconnect]`

  The take stream lost its connection, for any reason including a
  clean shutdown. Metadata: `:client`, and `:reason` — a `Zizq.Error`
  or `:closed`.

  Reconnection is automatic for anything retryable, so disconnects are
  expected in normal operation and are worth alerting on by rate
  rather than by occurrence.
  """

  @doc false
  # Prefixed here so no call site can misspell the namespace, and so
  # the event list above is the only place the names are written out.
  @spec span([atom()], :telemetry.event_metadata(), (-> {result, :telemetry.event_metadata()})) ::
          result
        when result: term()
  def span(suffix, metadata, fun), do: :telemetry.span([:zizq | suffix], metadata, fun)

  @doc false
  @spec emit([atom()], :telemetry.event_metadata()) :: :ok
  def emit(suffix, metadata) do
    :telemetry.execute([:zizq | suffix], %{system_time: System.system_time()}, metadata)
  end
end
