# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Backoff do
  @moduledoc """
  Per-job retry backoff policy.

  The server computes each retry delay as:

      delay = base + (attempts ** exponent) * 1000 + attempts * rand(0..jitter)

  `:base` and `:jitter` are **milliseconds**; `:exponent` is
  dimensionless. All three are required together — the server has no
  partial defaults.

      Zizq.Backoff.new!(base: :timer.seconds(15), exponent: 4.0, jitter: :timer.seconds(30))

  Omit the policy entirely to inherit the server's own default, which
  then tracks server configuration rather than freezing a value into
  your code.
  """

  @type t :: %__MODULE__{base: non_neg_integer(), exponent: float(), jitter: non_neg_integer()}

  @enforce_keys [:base, :exponent, :jitter]
  defstruct [:base, :exponent, :jitter]

  @doc "Build a policy from a keyword list or map. Raises on missing or invalid keys."
  @spec new!(t() | keyword() | map()) :: t()
  def new!(%__MODULE__{} = backoff), do: backoff

  def new!(opts) do
    opts = Map.new(opts)

    with {:ok, base} <- fetch_ms(opts, :base),
         {:ok, jitter} <- fetch_ms(opts, :jitter),
         {:ok, exponent} <- fetch_exponent(opts) do
      %__MODULE__{base: base, exponent: exponent, jitter: jitter}
    else
      {:error, message} ->
        raise ArgumentError, "invalid backoff: #{message} (got: #{inspect(opts)})"
    end
  end

  @doc false
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = b) do
    %{"base_ms" => b.base, "exponent" => b.exponent, "jitter_ms" => b.jitter}
  end

  @doc false
  @spec from_wire(map()) :: t()
  def from_wire(%{"base_ms" => base, "exponent" => exponent, "jitter_ms" => jitter}) do
    %__MODULE__{base: base, exponent: exponent / 1, jitter: jitter}
  end

  defp fetch_ms(opts, key) do
    case Map.fetch(opts, key) do
      {:ok, value} when is_integer(value) and value >= 0 ->
        {:ok, value}

      {:ok, other} ->
        {:error,
         "#{inspect(key)} must be a non-negative integer in milliseconds, got #{inspect(other)}"}

      :error ->
        {:error, "#{inspect(key)} is required"}
    end
  end

  # Accept an integer for convenience — `exponent: 4` is a natural
  # thing to write — but the wire field is a float.
  defp fetch_exponent(opts) do
    case Map.fetch(opts, :exponent) do
      {:ok, value} when is_number(value) and value >= 0 -> {:ok, value / 1}
      {:ok, other} -> {:error, ":exponent must be a non-negative number, got #{inspect(other)}"}
      :error -> {:error, ":exponent is required"}
    end
  end
end
