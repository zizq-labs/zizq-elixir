# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.BudgetChange do
  @moduledoc """
  The outcome of changing the budgets of many jobs at once.

      %Zizq.BudgetChange{changed: 12, blocked: ["01K9...", "01KA..."]}

  ## `:blocked`

  Only queued (`:scheduled`, `:ready`) jobs can be rebound: an
  in-flight job already debited against its budgets, and terminal jobs
  are immutable by design. Rather than skipping those silently, the
  server names the ones that *would* have changed but could not.

  They are always in-flight jobs, so the list is a retry list — they
  drain on their own, and the same call afterwards will pick them up:

      %{blocked: []} = MyApp.retry_until_clear(fn ->
        Zizq.query(MyApp.Zizq)
        |> Zizq.Query.where(queue: "emails")
        |> Zizq.Query.unbind_budget("stripe")
      end)

  A job that matched the filter and needed no change is counted in
  neither: it is not `:changed`, because nothing changed, and not
  `:blocked`, because nothing was in the way.
  """

  @type t :: %__MODULE__{changed: non_neg_integer(), blocked: [String.t()]}

  defstruct changed: 0, blocked: []

  @doc "Whether every matching job was changed."
  @spec complete?(t()) :: boolean()
  def complete?(%__MODULE__{blocked: blocked}), do: blocked == []

  @doc false
  @spec from_wire(map()) :: t()
  def from_wire(wire) do
    %__MODULE__{changed: wire["changed"] || 0, blocked: wire["blocked"] || []}
  end
end
