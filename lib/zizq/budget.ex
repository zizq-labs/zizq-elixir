# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Budget do
  @moduledoc """
  A named token bucket that jobs draw from to control throughput.

  A job bound to a budget dispatches only when its defined cost can be
  debited from the budget. When it cannot, it waits — it is not failed,
  and it does not leave the queue. Two strategies decide how tokens are
  managed:

      # A rate limit: 100 dispatches per minute.
      Zizq.Budget.new!(
        key: "emails",
        allocation: 100,
        strategy: :time_based,
        duration: :timer.minutes(1)
      )

      # A concurrency limit: at most 3 running at once.
      Zizq.Budget.new!(
        key: "stripe",
        allocation: 3,
        strategy: :while_in_flight
      )

  `:duration` is in **milliseconds**.

  ## `:time_based`

  Tokens accrue on a continuous drip rather than in fixed windows, so an
  empty bucket is half full after half the duration has passed. There is
  no fixed window boundary around which sudden spikes occur.

  A bucket starts full, which means `100` per minute really does permit
  two hundred dispatches in the first minute before settling to its
  long-run rate.

  ## `:burst`

  Caps how many tokens the bucket may hold at once, and so caps that
  opening spike without changing the long-run rate, while also capping
  the natural burst that would be permitted if the budget had sat idle
  for its total duration:

      Zizq.Budget.new!(
        key: "emails",
        allocation: 100,
        strategy: :time_based,
        duration: :timer.minutes(1),
        burst: 5
      )

  A `:burst` of `1` paces dispatches evenly with no overshoot at all. It
  also applies to a bucket that has gone unused: idling for an hour does
  not bank an hour's worth of tokens.

  A burst *above* the allocation is meaningful too — it keeps filling
  across consecutive periods, so `200` on an allocation of `100` accrues
  over two periods, but no further.

  ## `:while_in_flight`

  Has no clock. Its tokens are released when a job stops running, so it
  is a limit on how much work is in flight rather than on how often work
  starts. It takes neither `:duration` nor `:burst`, and passing either
  raises rather than being ignored — a budget that reads as though it
  set a refill period but did not is worse than a rejected one.

  ## Capacity

  A job's cost has to fit inside `capacity/1` — the burst where one is
  set, and the allocation otherwise. With a burst set it is the
  *smaller* number that decides whether a job can ever run, so a cost
  well within the allocation may still be refused.

  ## Bindings

  Budgets are shared resources and Jobs are bound to named budgets.
  Typically jobs will bind to just one budget to enforce a rate limit or
  concurrency limit on that job, but they may also bound to more than
  one budget, in which case all budgets must be satisfied before the job
  is dispatched by the server. Strategies can be freely mixed. For
  example, you have have a rate limit on some upstream system that you
  need to adhere to, while also requiring a concurrency control on one
  particular job that hits that system.
  """

  @type strategy :: :time_based | :while_in_flight

  @type t :: %__MODULE__{
          key: String.t(),
          allocation: pos_integer(),
          strategy: strategy(),
          duration: pos_integer() | nil,
          burst: pos_integer() | nil,
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @enforce_keys [:key, :allocation, :strategy]
  defstruct [:key, :allocation, :strategy, :duration, :burst, :created_at, :updated_at]

  @strategies [:time_based, :while_in_flight]

  # `:created_at` and `:updated_at` are populated by the server on a
  # read and are not accepted from a caller — a budget's identity is not
  # something a definition gets to assert.
  @write_keys [:key, :allocation, :strategy, :duration, :burst]

  @doc """
  Build a budget from a keyword list or map. Raises on invalid input.

  Validation is deliberate rather than permissive: a `:duration` on a
  `:while_in_flight` budget raises instead of being dropped, matching
  the server, which parses the strategy tag by hand for exactly this
  reason.
  """
  @spec new!(t() | keyword() | map()) :: t()
  def new!(%__MODULE__{} = budget), do: budget

  def new!(opts) do
    opts = Map.new(opts)

    case Map.keys(opts) -- @write_keys do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown budget keys: #{inspect(unknown)}"
    end

    budget = %__MODULE__{
      key: fetch_key!(opts),
      allocation: fetch_pos!(opts, :allocation, required: true),
      strategy: fetch_strategy!(opts),
      duration: fetch_pos!(opts, :duration),
      burst: fetch_pos!(opts, :burst)
    }

    validate_strategy_fields!(budget)
  end

  @doc """
  Most tokens the bucket can hold, which is what a job's cost must fit
  inside.

  This is the burst where one is set, and the allocation otherwise.
  """
  @spec capacity(t()) :: pos_integer()
  def capacity(%__MODULE__{burst: nil, allocation: allocation}), do: allocation
  def capacity(%__MODULE__{burst: burst}), do: burst

  @doc "Whether tokens accrue on a clock."
  @spec time_based?(t()) :: boolean()
  def time_based?(%__MODULE__{strategy: strategy}), do: strategy == :time_based

  @doc "Whether tokens are released when a job stops running."
  @spec while_in_flight?(t()) :: boolean()
  def while_in_flight?(%__MODULE__{strategy: strategy}), do: strategy == :while_in_flight

  # The request body only. The key travels in the path, and the
  # timestamps are the server's to report.
  @doc false
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = budget) do
    %{"allocation" => budget.allocation, "strategy" => strategy_to_wire(budget)}
  end

  @doc false
  @spec from_wire(map()) :: t()
  def from_wire(wire) do
    strategy = Map.get(wire, "strategy") || %{}

    %__MODULE__{
      key: wire["key"],
      allocation: wire["allocation"],
      strategy: strategy_from_wire(strategy["type"]),
      duration: strategy["duration_ms"],
      burst: strategy["burst"],
      created_at: Zizq.Timestamp.from_ms(wire["created_at"]),
      updated_at: Zizq.Timestamp.from_ms(wire["updated_at"])
    }
  end

  defp strategy_to_wire(%__MODULE__{strategy: :while_in_flight}) do
    %{"type" => "while_in_flight"}
  end

  defp strategy_to_wire(%__MODULE__{strategy: :time_based} = budget) do
    %{"type" => "time_based", "duration_ms" => budget.duration}
    |> maybe_put("burst", budget.burst)
  end

  # An unrecognised kind is passed through rather than raised on, so a
  # budget created by a newer server can still be read back and written
  # out unchanged instead of being silently rewritten.
  defp strategy_from_wire("time_based"), do: :time_based
  defp strategy_from_wire("while_in_flight"), do: :while_in_flight
  defp strategy_from_wire(other) when is_binary(other), do: String.to_atom(other)
  defp strategy_from_wire(nil), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp fetch_key!(opts) do
    case Map.fetch(opts, :key) do
      {:ok, key} when is_binary(key) and key != "" ->
        key

      {:ok, other} ->
        raise ArgumentError, "budget :key must be a non-empty string, got #{inspect(other)}"

      :error ->
        raise ArgumentError, "budget :key is required"
    end
  end

  defp fetch_strategy!(opts) do
    case Map.fetch(opts, :strategy) do
      {:ok, strategy} when strategy in @strategies ->
        strategy

      {:ok, other} ->
        raise ArgumentError,
              "budget :strategy must be one of #{inspect(@strategies)}, got #{inspect(other)}"

      :error ->
        raise ArgumentError, "budget :strategy is required"
    end
  end

  defp fetch_pos!(opts, key, options \\ []) do
    case Map.fetch(opts, key) do
      {:ok, value} when is_integer(value) and value > 0 ->
        value

      {:ok, nil} ->
        required!(key, options)

      :error ->
        required!(key, options)

      {:ok, other} ->
        raise ArgumentError,
              "budget #{inspect(key)} must be a positive integer, got #{inspect(other)}"
    end
  end

  defp required!(key, options) do
    if Keyword.get(options, :required, false) do
      raise ArgumentError, "budget #{inspect(key)} is required"
    end

    nil
  end

  defp validate_strategy_fields!(%__MODULE__{strategy: :time_based, duration: nil}) do
    raise ArgumentError,
          "a :time_based budget requires a :duration in milliseconds, " <>
            "e.g. duration: :timer.minutes(1)"
  end

  defp validate_strategy_fields!(%__MODULE__{strategy: :while_in_flight} = budget) do
    case Enum.reject([duration: budget.duration, burst: budget.burst], &is_nil(elem(&1, 1))) do
      [] ->
        budget

      set ->
        raise ArgumentError,
              ":while_in_flight has no clock, so it takes neither :duration nor :burst — " <>
                "got #{inspect(Keyword.keys(set))}. Use :time_based for a rate limit."
    end
  end

  defp validate_strategy_fields!(%__MODULE__{} = budget), do: budget
end
