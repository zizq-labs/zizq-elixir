# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Retention do
  @moduledoc """
  How long a job stays on the server after reaching a terminal state.

  Both values are **milliseconds**, and both are optional. The server's
  default applies for omitted fields.

      Zizq.Retention.new!(completed: :timer.hours(24), dead: :timer.hours(24 * 7))
  """

  @type t :: %__MODULE__{completed: non_neg_integer() | nil, dead: non_neg_integer() | nil}

  defstruct [:completed, :dead]

  @doc "Build a retention policy from a keyword list or map."
  @spec new!(t() | keyword() | map()) :: t()
  def new!(%__MODULE__{} = retention), do: retention

  def new!(opts) do
    opts = Map.new(opts)

    case Map.keys(opts) -- [:completed, :dead] do
      [] -> %__MODULE__{completed: ms!(opts, :completed), dead: ms!(opts, :dead)}
      unknown -> raise ArgumentError, "unknown retention keys: #{inspect(unknown)}"
    end
  end

  @doc false
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = r) do
    %{}
    |> maybe_put("completed_ms", r.completed)
    |> maybe_put("dead_ms", r.dead)
  end

  @doc false
  @spec from_wire(map()) :: t()
  def from_wire(wire) do
    %__MODULE__{completed: Map.get(wire, "completed_ms"), dead: Map.get(wire, "dead_ms")}
  end

  defp ms!(opts, key) do
    case Map.fetch(opts, key) do
      :error ->
        nil

      {:ok, nil} ->
        nil

      {:ok, value} when is_integer(value) and value >= 0 ->
        value

      {:ok, other} ->
        raise ArgumentError,
              "retention #{inspect(key)} must be a non-negative integer in milliseconds, " <>
                "got #{inspect(other)}"
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
