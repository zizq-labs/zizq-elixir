# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.CronEntry do
  @moduledoc """
  One scheduled job within a cron group.

  An entry pairs a cron expression with a job to enqueue when it
  fires. The job is an ordinary `Zizq.Enqueue`, so anything that can
  be enqueued can be scheduled — including one built by a
  `Zizq.JobKind` module.

  ## Fields

    * `:name` — unique within its group.
    * `:expression` — a cron expression, e.g. `"*/15 * * * *"`.
    * `:timezone` — an IANA name, e.g. `"Australia/Melbourne"`. Its
      group's timezone when unset, or the server's own when the group
      does not specify one either.
    * `:paused` — whether this entry is currently suspended.
    * `:job` — the `Zizq.Enqueue` fired on schedule.
    * `:next_enqueue_at`, `:last_enqueue_at` — when it fires next, and
      when it last did. Read-only.
    * `:paused_at`, `:resumed_at` — when it was last suspended and
      resumed. Read-only.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          expression: String.t(),
          timezone: String.t() | nil,
          paused: boolean() | nil,
          paused_at: DateTime.t() | nil,
          resumed_at: DateTime.t() | nil,
          job: Zizq.Enqueue.t() | nil,
          next_enqueue_at: DateTime.t() | nil,
          last_enqueue_at: DateTime.t() | nil
        }

  @enforce_keys [:name, :expression]
  defstruct [
    :name,
    :expression,
    :timezone,
    :paused,
    :paused_at,
    :resumed_at,
    :job,
    :next_enqueue_at,
    :last_enqueue_at
  ]

  @keys [:name, :expression, :timezone, :paused, :job]

  @doc """
  Build an entry from a keyword list or map.

  `:name`, `:expression` and `:job` are required. The job takes the
  same forms `Zizq.enqueue/2` does.
  """
  @spec new!(t() | keyword() | map()) :: t()
  def new!(%__MODULE__{} = entry), do: entry

  def new!(attrs) do
    attrs = Map.new(attrs)

    case Map.keys(attrs) -- @keys do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown cron entry key#{if length(unknown) > 1, do: "s"}: " <>
                "#{inspect(unknown)}. Known keys are #{inspect(@keys)}"
    end

    %__MODULE__{
      name: require_string!(attrs, :name),
      expression: require_string!(attrs, :expression),
      timezone: Map.get(attrs, :timezone),
      paused: Map.get(attrs, :paused),
      job: attrs |> Map.get(:job) |> job!()
    }
  end

  defp require_string!(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        value

      {:ok, other} ->
        raise ArgumentError,
              "cron entry #{inspect(key)} must be a non-empty string, got #{inspect(other)}"

      :error ->
        raise ArgumentError, "cron entry #{inspect(key)} is required"
    end
  end

  defp job!(nil), do: raise(ArgumentError, "cron entry :job is required")

  defp job!(job) do
    enqueue = Zizq.Enqueue.new!(job)

    # The schedule decides when this runs, so a job template carrying
    # its own start time would be two answers to one question. The
    # server rejects it; this says so at the call site.
    if enqueue.ready_at do
      raise ArgumentError,
            "a cron entry's :job cannot set :ready_at — the cron expression decides " <>
              "when it runs"
    end

    enqueue
  end

  @doc false
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = entry) do
    %{"name" => entry.name, "expression" => entry.expression, "job" => job_wire(entry.job)}
    |> maybe_put("timezone", entry.timezone)
    |> maybe_put("paused", entry.paused)
  end

  defp job_wire(nil), do: nil
  defp job_wire(job), do: Zizq.Enqueue.to_wire(job)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc false
  @spec from_wire(map()) :: t()
  def from_wire(wire) do
    %__MODULE__{
      name: wire["name"],
      expression: wire["expression"],
      timezone: wire["timezone"],
      paused: wire["paused"],
      paused_at: Zizq.Timestamp.from_ms(wire["paused_at"]),
      resumed_at: Zizq.Timestamp.from_ms(wire["resumed_at"]),
      job: wire["job"] && Zizq.Enqueue.new!(job_attrs(wire["job"])),
      next_enqueue_at: Zizq.Timestamp.from_ms(wire["next_enqueue_at"]),
      last_enqueue_at: Zizq.Timestamp.from_ms(wire["last_enqueue_at"])
    }
  end

  # The job comes back in wire form — string keys, `_ms` suffixes — so
  # it is turned back into the same struct a caller would have built.
  defp job_attrs(wire) do
    %{
      type: wire["type"],
      queue: wire["queue"] || "default",
      payload: wire["payload"],
      priority: wire["priority"],
      retry_limit: wire["retry_limit"],
      backoff: wire["backoff"] && Zizq.Backoff.from_wire(wire["backoff"]),
      retention: wire["retention"] && Zizq.Retention.from_wire(wire["retention"]),
      unique_key: wire["unique_key"],
      unique_while: wire["unique_while"] && String.to_existing_atom(wire["unique_while"])
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end
end
