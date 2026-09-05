# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.BudgetBinding do
  @moduledoc """
  A job's claim on a budget: which budget, and what it costs to
  dispatch.

      Zizq.BudgetBinding.new!(key: "emails", cost: 2)

  Bindings are passed to the server as part of the enqueue operation,
  and so usually declared on a job module:

      defmodule MyApp.SendEmail do
        use Zizq.JobKind,
          type: "send_email",
          queue: "emails",
          budgets: [[key: "emails", cost: 2]]

        @impl Zizq.JobKind
        def perform(payload), do: MyApp.Mailer.deliver(payload)
      end

  ## `:cost`

  How many tokens one job debits from the budget when it dispatches,
  defaulting to `1`. Jobs can therefore weigh differently against the
  same budget — a bulk send costing `10` against an allocation of `100`
  leaves room for 90 more single sends.

  A cost has to fit inside the budget's `Zizq.Budget.capacity/1`, or the
  job would forever be held back from dispatching. The server refuses a
  binding that does not satisfy the invariant.

  ## `:create_with`

  Declares the budget's policy should it not exist yet, so binding and
  creating happen in one atomic request rather than over two:

      Zizq.BudgetBinding.new!(
        key: "emails",
        cost: 2,
        create_with: [
          allocation: 100,
          strategy: :time_based,
          duration: :timer.minutes(1)
        ]
      )

  The key comes from the binding, so it is not repeated. It is ignored
  when the budget already exists — the server stays authoritative.

  Without it, the budget has to exist before a job can bind to it.
  """

  alias Zizq.Budget

  @type t :: %__MODULE__{
          key: String.t(),
          cost: pos_integer() | nil,
          create_with: Budget.t() | nil
        }

  @enforce_keys [:key]
  defstruct [:key, :cost, :create_with]

  @keys [:key, :cost, :create_with]

  @doc """
  Build a binding from a keyword list or map. Raises on invalid input.
  """
  @spec new!(t() | keyword() | map()) :: t()
  def new!(%__MODULE__{} = binding), do: binding

  def new!(attrs) do
    attrs = Map.new(attrs)

    case Map.keys(attrs) -- @keys do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown budget binding keys: #{inspect(unknown)}"
    end

    key = fetch_key!(attrs)

    %__MODULE__{
      key: key,
      cost: fetch_cost!(attrs),
      create_with: build_policy!(attrs, key)
    }
  end

  @doc false
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = binding) do
    %{"key" => binding.key}
    |> maybe_put("cost", binding.cost)
    |> maybe_put("create_with", binding.create_with && Budget.to_wire(binding.create_with))
  end

  # Reads carry a resolved `cost` and never a `create_with`.
  @doc false
  @spec from_wire(map()) :: t()
  def from_wire(wire) do
    %__MODULE__{key: wire["key"], cost: wire["cost"]}
  end

  defp fetch_key!(attrs) do
    case Map.fetch(attrs, :key) do
      {:ok, key} when is_binary(key) and key != "" ->
        key

      {:ok, other} ->
        raise ArgumentError,
              "budget binding :key must be a non-empty string, got #{inspect(other)}"

      :error ->
        raise ArgumentError, "budget binding :key is required"
    end
  end

  defp fetch_cost!(attrs) do
    case Map.fetch(attrs, :cost) do
      :error ->
        nil

      {:ok, nil} ->
        nil

      {:ok, cost} when is_integer(cost) and cost > 0 ->
        cost

      {:ok, other} ->
        raise ArgumentError,
              "budget binding :cost must be a positive integer, got #{inspect(other)}"
    end
  end

  # The policy is a whole `Zizq.Budget`, so it gets that module's
  # validation — including refusing a `:duration` on a clockless
  # strategy. The key is supplied from the binding rather than asked
  # for twice.
  defp build_policy!(attrs, key) do
    case Map.fetch(attrs, :create_with) do
      :error -> nil
      {:ok, nil} -> nil
      {:ok, %Budget{} = budget} -> %{budget | key: key}
      {:ok, policy} -> policy |> Map.new() |> Map.put(:key, key) |> Budget.new!()
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
