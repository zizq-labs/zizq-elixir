# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Cron do
  @moduledoc """
  A named group of scheduled jobs.

  The same struct is used for both input and what the server returns,
  so installing a schedule and amending one use the same shape:

      Zizq.Cron.new("my_app")
      |> Zizq.Cron.put_entry(
        name: "nightly_cleanup",
        expression: "0 3 * * *",
        job: MyApp.Cleanup.new(%{})
      )
      |> Zizq.replace_cron(MyApp.Zizq)

  Declared all at once instead, if that reads better:

      Zizq.Cron.new("my_app",
        entries: [
          [name: "nightly_cleanup", expression: "0 3 * * *", job: MyApp.Cleanup.new(%{})]
        ]
      )
      |> Zizq.replace_cron(MyApp.Zizq)

  Groups exist so a schedule can be replaced, paused or removed as a
  unit — typically one group per application, holding every entry that
  application owns.

  Normally the schedule lives in code and is installed on boot.
  Installing is atomic and idempotent, so every instance of an
  application can do it on startup without coordinating.

  ## Amending a schedule already on the server

  A schedule can also be read, changed and put back:

      Zizq.get_cron!("my_app", MyApp.Zizq)
      |> Zizq.Cron.delete_entry("nightly_cleanup")
      |> Zizq.replace_cron(MyApp.Zizq)

  This suits one-off changes made by one operator. It reads and writes
  as two steps, so it is not the way to make a change from running
  application code where several instances might do it at once — for
  that, `Zizq.pause_cron_entry/2` and `Zizq.delete_cron_entry/2`
  change a single entry in one request.

  ## Fields

    * `:name` — the group's name.
    * `:entries` — the `Zizq.CronEntry` structs it holds.
    * `:timezone` — an IANA name, e.g. `"Australia/Melbourne"`,
      applied to every entry that does not specify one of its own. The
      server's own timezone when unset. Because installing replaces
      the group whole, leaving it out clears the timezone.
    * `:paused` — whether the whole group is suspended. A paused group
      fires nothing, whatever its entries say. Left `nil`, an existing
      group keeps its current state and a new one starts running.
    * `:paused_at`, `:resumed_at` — when it was last suspended and
      resumed. Read-only.

  ## Timezones

  Most schedules want one timezone throughout, which is what the
  group's `:timezone` is for:

      Zizq.Cron.new("my_app",
        timezone: "Australia/Melbourne",
        entries: [
          [name: "nightly_cleanup", expression: "0 3 * * *", job: MyApp.Cleanup.new(%{})]
        ]
      )

  An entry specifying its own `:timezone` uses that instead, so one
  schedule can hold entries in several zones. With neither set, the
  server evaluates the expression in its own local timezone.

  Requires Zizq 0.7.0 or newer on the server. Against an older server
  the group's timezone is ignored, and entries fall back to the
  server's local timezone.
  """

  alias Zizq.CronEntry

  @type t :: %__MODULE__{
          name: String.t() | nil,
          timezone: String.t() | nil,
          paused: boolean() | nil,
          paused_at: DateTime.t() | nil,
          resumed_at: DateTime.t() | nil,
          entries: [CronEntry.t()]
        }

  defstruct [:name, :timezone, :paused, :paused_at, :resumed_at, entries: []]

  @doc """
  Build a schedule.

  ## Options

    * `:entries` — `Zizq.CronEntry` structs, keyword lists or maps.
    * `:timezone` — an IANA name applied to entries that do not specify
      one of their own.
    * `:paused` — whether the group starts suspended.
  """
  @spec new(String.t(), keyword()) :: t()
  def new(name, opts \\ []) when is_binary(name) do
    case Keyword.keys(opts) -- [:entries, :timezone, :paused] do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown cron options: #{inspect(unknown)}"
    end

    %__MODULE__{
      name: name,
      timezone: Keyword.get(opts, :timezone),
      paused: Keyword.get(opts, :paused),
      entries: opts |> Keyword.get(:entries, []) |> Enum.map(&CronEntry.new!/1)
    }
  end

  @doc """
  Add an entry, or replace the one with that name.

  Upsert rather than append, so putting the same schedule twice leaves
  one entry — the behaviour the whole group already has when
  installed twice.
  """
  @spec put_entry(t(), CronEntry.t() | keyword() | map()) :: t()
  def put_entry(%__MODULE__{} = cron, entry) do
    entry = CronEntry.new!(entry)

    case Enum.find_index(cron.entries, &(&1.name == entry.name)) do
      nil -> %{cron | entries: cron.entries ++ [entry]}
      index -> %{cron | entries: List.replace_at(cron.entries, index, entry)}
    end
  end

  @doc """
  Remove an entry by name. Removing one that is not there changes
  nothing.
  """
  @spec delete_entry(t(), String.t()) :: t()
  def delete_entry(%__MODULE__{} = cron, name) when is_binary(name) do
    %{cron | entries: Enum.reject(cron.entries, &(&1.name == name))}
  end

  @doc """
  Look up one entry by name, or `nil`.
  """
  @spec entry(t(), String.t()) :: CronEntry.t() | nil
  def entry(%__MODULE__{entries: entries}, name) do
    Enum.find(entries, &(&1.name == name))
  end

  @doc false
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = cron) do
    %{"entries" => Enum.map(cron.entries, &CronEntry.to_wire/1)}
    |> maybe_put("timezone", cron.timezone)
    |> maybe_put("paused", cron.paused)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc false
  @spec from_wire(map()) :: t()
  def from_wire(wire) do
    %__MODULE__{
      name: wire["name"],
      timezone: wire["timezone"],
      paused: wire["paused"],
      paused_at: Zizq.Timestamp.from_ms(wire["paused_at"]),
      resumed_at: Zizq.Timestamp.from_ms(wire["resumed_at"]),
      entries: Enum.map(wire["entries"] || [], &CronEntry.from_wire/1)
    }
  end
end
