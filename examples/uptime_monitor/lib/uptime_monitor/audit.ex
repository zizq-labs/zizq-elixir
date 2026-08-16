defmodule UptimeMonitor.Audit do
  @moduledoc """
  Emits `audit.create` events into the audit log's queue.

  This is a **cross-language producer**. It shares no code with the
  consumer — see the `audit_log` example alongside this one — only a
  job type, a queue name and the shape of a payload. The consumer
  happens to be written in Elixir here; it could equally be the Ruby,
  Node or Rust one, and nothing on this side would change.

  Every call site in this app funnels through here so the wire format
  stays consistent, and so the timestamp is spelled the one way the
  sink accepts.
  """

  require Logger

  alias UptimeMonitor.Jobs

  @audit_type "audit.create"

  @doc """
  Enqueue an audit event.

  ## Options

    * `:event_type` — dot-namespaced, e.g. `"url.status.changed"`.
      Required.
    * `:text` — a human-readable summary.
    * `:resource` — what it happened to, e.g. `"monitored_url:42"`.
    * `:data` — a map of anything else worth recording.
    * `:actor` — who did it. Defaults to `"system"`, since most
      events here are the worker's doing rather than a person's.
    * `:occurred_at` — defaults to now.

  Always returns `:ok`. A failure to enqueue is logged rather than
  raised: the caller has already done the work being audited, so
  failing it would repeat a side effect to record that it happened.
  """
  @spec emit(keyword()) :: :ok
  def emit(event) do
    payload = %{
      # ISO8601 is the only form the sink accepts — see the audit_log
      # example's README for the contract.
      "occurred_at" =>
        event |> Keyword.get(:occurred_at, DateTime.utc_now()) |> DateTime.to_iso8601(),
      "source" => source(),
      "event_type" => Keyword.fetch!(event, :event_type),
      "actor" => Keyword.get(event, :actor, "system"),
      "ip" => Keyword.get(event, :ip),
      "resource" => Keyword.get(event, :resource),
      "text" => Keyword.get(event, :text),
      "data" => Keyword.get(event, :data)
    }

    enqueue = [type: @audit_type, queue: queue(), payload: payload]

    case Zizq.enqueue(enqueue, Jobs.client()) do
      {:ok, _job} ->
        :ok

      {:error, error} ->
        Logger.warning(
          "[uptime_monitor] could not emit #{payload["event_type"]}: #{Exception.message(error)}"
        )

        :ok
    end
  end

  @doc """
  The queue audit events are written to.

  Point it at a queue nothing consumes to turn auditing off.
  """
  @spec queue() :: String.t()
  def queue, do: Application.get_env(:uptime_monitor, :audit_queue, "audit")

  @doc """
  The name this app is recorded under in the audit log.
  """
  @spec source() :: String.t()
  def source, do: Application.get_env(:uptime_monitor, :audit_source, "uptime_monitor")

  @doc """
  The job type the audit sink dispatches on.
  """
  @spec audit_type() :: String.t()
  def audit_type, do: @audit_type
end
