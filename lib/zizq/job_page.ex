# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.JobPage do
  @moduledoc """
  One page of a job listing, and where the next one is.

  Returned by `Zizq.list_jobs/2`. Follow it with
  `Zizq.next_page/2`, which returns `nil` once there are no more:

      {:ok, page} = Zizq.list_jobs([queue: "emails"], MyApp.Zizq)

      case Zizq.next_page(page, MyApp.Zizq) do
        {:ok, nil} -> :done
        {:ok, next} -> handle(next)
      end

  The links are opaque paths the server builds, carrying the cursor
  and every filter of the original request.

  Follow `Zizq.prev_page/2` to go the other direction.
  """

  @type t :: %__MODULE__{
          jobs: [Zizq.Job.t()],
          self: String.t() | nil,
          next: String.t() | nil,
          prev: String.t() | nil
        }

  defstruct jobs: [], self: nil, next: nil, prev: nil

  @doc false
  @spec from_wire(map()) :: t()
  def from_wire(%{"jobs" => jobs} = wire) do
    pages = Map.get(wire, "pages") || %{}

    %__MODULE__{
      jobs: Enum.map(jobs, &Zizq.Job.from_wire/1),
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
