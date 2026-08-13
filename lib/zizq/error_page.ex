# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.ErrorPage do
  @moduledoc """
  One page of a job's failed attempts, and where the next one is.

  Returned by `Zizq.list_errors/3`, and followed with
  `Zizq.next_page/2` and `Zizq.prev_page/2`.
  """

  @type t :: %__MODULE__{
          errors: [Zizq.ErrorRecord.t()],
          self: String.t() | nil,
          next: String.t() | nil,
          prev: String.t() | nil
        }

  defstruct errors: [], self: nil, next: nil, prev: nil

  @doc false
  @spec from_wire(map()) :: t()
  def from_wire(%{"errors" => errors} = wire) do
    pages = Map.get(wire, "pages") || %{}

    %__MODULE__{
      errors: Enum.map(errors, &Zizq.ErrorRecord.from_wire/1),
      self: pages["self"],
      next: pages["next"],
      prev: pages["prev"]
    }
  end

  @doc """
  Whether another page follows this one.
  """
  @spec has_next?(t()) :: boolean()
  def has_next?(%__MODULE__{next: next}), do: not is_nil(next)

  @doc """
  Whether a page precedes this one.
  """
  @spec has_prev?(t()) :: boolean()
  def has_prev?(%__MODULE__{prev: prev}), do: not is_nil(prev)
end
