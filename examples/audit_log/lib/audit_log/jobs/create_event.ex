# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule AuditLog.Jobs.CreateEvent do
  @moduledoc """
  Stores one audit event sent by a producer.

  This module exists to **run** the job, not to enqueue it. The audit
  log is a sink: every producer lives in another application, and may
  be written in another language. So no enqueue defaults are declared
  here — a producer sets its own, and would not see these anyway.

  What is shared with producers is the `:type` string and the payload
  shape. That is the whole contract:

      {
        "occurred_at": "2026-08-15T10:15:00Z",
        "source":      "uptime_monitor",
        "event_type":  "url.status.changed",
        "actor":       "system",
        "ip":          null,
        "resource":    "monitored_url:42",
        "text":        "https://example.com went down",
        "data":        {"from": "up", "to": "down"}
      }

  Only `occurred_at`, `source` and `event_type` are required. The sink
  does not interpret `event_type` — it stores it.
  """

  use Zizq.JobKind, type: "audit.create"

  @impl Zizq.JobKind
  def perform(payload) when is_map(payload) do
    case AuditLog.record_payload(payload) do
      {:ok, _event} ->
        :ok

      # Cancelled rather than failed. A payload the producer got wrong
      # will be just as wrong on the next attempt, so retrying it only
      # delays the job dying with the same message — and burns the
      # backoff schedule on something that cannot come good.
      {:error, changeset} ->
        {:cancel, "invalid audit event: #{AuditLog.describe_errors(changeset)}"}
    end
  end

  # A payload that is not a JSON object at all, which no producer
  # should send but nothing on the wire prevents.
  def perform(payload) do
    {:cancel, "expected a JSON object payload, got: #{inspect(payload)}"}
  end
end
