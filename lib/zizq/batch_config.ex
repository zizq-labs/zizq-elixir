# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.BatchConfig do
  @moduledoc """
  Batching configuration: fold an enqueue into an existing `:ready` job
  rather than creating a new one.

  While a batch is enqueued, each further enqueue sharing its `:key` is
  evaluated against the `:when` predicate. If that returns true the
  payloads are merged by `:fold`; otherwise the batch is sealed and a
  new one starts.

  Both `:when` and `:fold` are jq expressions evaluated with `$existing`
  bound to the currently enqueued batch's payload and `$new` bound to
  the incoming job's payload.

      Zizq.BatchConfig.new!(
        key: "digest:tenant-42",
        when: "$existing.count < 100",
        fold: "$existing | .count += 1 | .ids += $new.ids"
      )

  Batching is a Pro-licensed feature; without one the server responds
  403, which surfaces as `%Zizq.Error{reason: :forbidden}`.

  The configuration is also returned on job reads. The *first*
  enqueue's `:when` and `:fold` govern the whole batch, so seeing what
  is stored reveals the conditions currently applied to batched jobs.
  """

  @type t :: %__MODULE__{key: String.t(), when: String.t(), fold: String.t()}

  @enforce_keys [:key, :when, :fold]
  defstruct [:key, :when, :fold]

  @keys [:key, :when, :fold]

  @doc "Build a batch configuration from a keyword list or map."
  @spec new!(t() | keyword() | map()) :: t()
  def new!(%__MODULE__{} = batch), do: batch

  def new!(attrs) do
    attrs = Map.new(attrs)

    case Map.keys(attrs) -- @keys do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown batch keys: #{inspect(unknown)}"
    end

    %__MODULE__{
      key: fetch_string!(attrs, :key),
      when: fetch_string!(attrs, :when),
      fold: fetch_string!(attrs, :fold)
    }
  end

  @doc false
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = b) do
    %{"key" => b.key, "when" => b.when, "fold" => b.fold}
  end

  @doc false
  @spec from_wire(map()) :: t()
  def from_wire(%{"key" => key, "when" => when_expr, "fold" => fold}) do
    %__MODULE__{key: key, when: when_expr, fold: fold}
  end

  defp fetch_string!(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        value

      {:ok, other} ->
        raise ArgumentError,
              "batch #{inspect(key)} must be a non-empty string, got #{inspect(other)}"

      :error ->
        raise ArgumentError, "batch #{inspect(key)} is required"
    end
  end
end
