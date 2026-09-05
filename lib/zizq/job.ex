# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Job do
  @moduledoc """
  A job record from the server.

  Returned by `Zizq.enqueue/2`, yielded by the take stream, and listed
  by the query API. Which fields are populated depends on the job's
  lifecycle state — `:dequeued_at` is only set once a worker has taken
  it, `:completed_at` only once it has finished — so treat anything
  optional as possibly `nil`.

  Timestamps are `t:DateTime.t/0` in UTC.
  """

  alias Zizq.Backoff
  alias Zizq.BatchConfig
  alias Zizq.Retention

  @typedoc """
  Lifecycle state.

    * `:scheduled` — stored, but scheduled for a future date/time and
      not eligible until `:ready_at` is reached — also used for
      retries when `:attempts` is non-zero
    * `:ready` — queued and waiting for a worker when it reaches the
      too of the queue
    * `:in_flight` — delivered to a worker, awaiting acknowledgement
    * `:completed` — finished successfully
    * `:dead` — failed and exhausted its retry limit
  """
  @type status :: :scheduled | :ready | :in_flight | :completed | :dead

  @type t :: %__MODULE__{
          id: String.t(),
          type: String.t(),
          queue: String.t(),
          priority: non_neg_integer(),
          status: status(),
          payload: term(),
          ready_at: DateTime.t() | nil,
          attempts: non_neg_integer(),
          retry_limit: non_neg_integer() | nil,
          backoff: Backoff.t() | nil,
          retention: Retention.t() | nil,
          batch: BatchConfig.t() | nil,
          budgets: [Zizq.BudgetBinding.t()],
          dequeued_at: DateTime.t() | nil,
          failed_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          purge_at: DateTime.t() | nil,
          unique_key: String.t() | nil,
          unique_while: String.t() | nil,
          duplicate: boolean() | nil,
          folded: boolean() | nil
        }

  defstruct [
    :id,
    :type,
    :queue,
    :priority,
    :status,
    :payload,
    :ready_at,
    :attempts,
    :retry_limit,
    :backoff,
    :retention,
    :batch,
    :budgets,
    :dequeued_at,
    :failed_at,
    :completed_at,
    :purge_at,
    :unique_key,
    :unique_while,
    :duplicate,
    :folded
  ]

  @statuses %{
    "scheduled" => :scheduled,
    "ready" => :ready,
    "in_flight" => :in_flight,
    "completed" => :completed,
    "dead" => :dead
  }

  @doc false
  # Decodes a server response. Unknown statuses are kept as the raw
  # string rather than raising: a newer server adding a state should
  # not break an older client that never inspects it.
  @spec from_wire(map()) :: t()
  def from_wire(wire) when is_map(wire) do
    %__MODULE__{
      id: wire["id"],
      type: wire["type"],
      queue: wire["queue"],
      priority: wire["priority"],
      status: status(wire["status"]),
      payload: wire["payload"],
      attempts: wire["attempts"],
      retry_limit: wire["retry_limit"],
      unique_key: wire["unique_key"],
      unique_while: wire["unique_while"],
      duplicate: wire["duplicate"],
      folded: wire["folded"],
      backoff: sub(wire["backoff"], &Backoff.from_wire/1),
      retention: sub(wire["retention"], &Retention.from_wire/1),
      batch: sub(wire["batch"], &BatchConfig.from_wire/1),
      budgets: Enum.map(wire["budgets"] || [], &Zizq.BudgetBinding.from_wire/1),
      ready_at: Zizq.Timestamp.from_ms(wire["ready_at"]),
      dequeued_at: Zizq.Timestamp.from_ms(wire["dequeued_at"]),
      failed_at: Zizq.Timestamp.from_ms(wire["failed_at"]),
      completed_at: Zizq.Timestamp.from_ms(wire["completed_at"]),
      purge_at: Zizq.Timestamp.from_ms(wire["purge_at"])
    }
  end

  defp status(nil), do: nil
  defp status(value), do: Map.get(@statuses, value, value)

  defp sub(nil, _fun), do: nil
  defp sub(value, fun), do: fun.(value)
end
