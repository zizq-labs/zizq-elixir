# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Query do
  @moduledoc """
  A composable job query that handles pagination internally.

  Start one with `Zizq.query/1`, narrow it, then run it with anything
  from `Enum` or `Stream` — a query is enumerable, so pages are
  fetched as they are needed and no further:

      Zizq.query(MyApp.Zizq)
      |> Zizq.Query.where(queue: "emails", status: [:ready])
      |> Enum.take(10)

  That stops after the first page, because `Enum.take/2` stops asking.
  The same query run to completion walks every page:

      Zizq.query(MyApp.Zizq)
      |> Zizq.Query.where(queue: "emails")
      |> Enum.each(&IO.inspect/1)

  Building a query performs no request. Nothing is sent until it is
  enumerated, counted, or run through `update_all/2` or
  `delete_all/1`.

  ## Narrowing

  `where/2` takes the filters `Zizq.Filter` documents, and can be
  called repeatedly — later calls win per key, so a query can be
  built up in pieces:

      base = Zizq.query(MyApp.Zizq) |> Zizq.Query.where(queue: "emails")

      base |> Zizq.Query.where(status: :ready)
      base |> Zizq.Query.where(status: :dead)

  One `where/2` rather than a `by_queue`, `by_status`, `by_type` and
  so on for each field: the filters are already a keyword list, and
  the server takes them as one set.

  ## Counting

  `Enum.count/1` asks the server to count rather than fetching every
  page, so it costs one request whatever the total:

      Zizq.query(MyApp.Zizq) |> Zizq.Query.where(queue: "emails") |> Enum.count()

  ## Limits and page size

  `limit/2` caps how many jobs come back in total; `in_pages_of/2`
  sets how many are fetched per request. They are independent — the
  first is what you want, the second is how eagerly it is fetched.

  ## Working in batches

  `update_all/2` and `delete_all/1` normally send one request and let
  the server do the work from the filters, which is what you want for
  anything of ordinary size.

  Give the query a `limit/2` and/or an `in_pages_of/2` and they switch
  to working a page at a time instead, acting on each page by id:

      Zizq.query(MyApp.Zizq)
      |> Zizq.Query.where(queue: "emails", status: :dead)
      |> Zizq.Query.in_pages_of(1_000)
      |> Zizq.Query.delete_all()

  Ten million jobs then become a run of bounded requests rather than
  one enormous one. Each page's ids are sent *with* the original
  filters rather than instead of them, so a job that stopped matching
  between being listed and being acted on is left alone.

  The count returned is the total across every batch either way.
  """

  alias Zizq.Filter

  @type t :: %__MODULE__{
          client: atom(),
          filters: keyword(),
          limit: pos_integer() | nil,
          order: :asc | :desc | nil,
          page_size: pos_integer() | nil
        }

  @enforce_keys [:client]
  defstruct [:client, :limit, :order, :page_size, filters: []]

  @doc false
  @spec new(atom()) :: t()
  def new(client) when is_atom(client), do: %__MODULE__{client: client}

  @doc """
  Narrow the query. See `Zizq.Filter` for what can be given.

  Merges with what is already there, so later calls win per key.
  """
  @spec where(t(), keyword()) :: t()
  def where(%__MODULE__{} = query, filters) do
    # Validated as it is built rather than when it runs, so a typo
    # fails at the line that made it.
    _ = Filter.to_params(filters)

    %{query | filters: Keyword.merge(query.filters, filters)}
  end

  @doc """
  Return jobs oldest first (`:asc`) or newest first (`:desc`).
  """
  @spec order(t(), :asc | :desc) :: t()
  def order(%__MODULE__{} = query, direction) when direction in [:asc, :desc] do
    %{query | order: direction}
  end

  @doc """
  Cap how many jobs the query returns in total.
  """
  @spec limit(t(), pos_integer()) :: t()
  def limit(%__MODULE__{} = query, count) when is_integer(count) and count > 0 do
    %{query | limit: count}
  end

  @doc """
  Set how many jobs are fetched per request.

  Independent of `limit/2`: this is how eagerly the query pages, not
  how much it returns.
  """
  @spec in_pages_of(t(), pos_integer()) :: t()
  def in_pages_of(%__MODULE__{} = query, size) when is_integer(size) and size > 0 do
    %{query | page_size: size}
  end

  @doc """
  How many jobs the query would yield, without fetching them.

  One request whatever the total. `Enum.count/1` on a query calls
  this.

  A `limit/2` caps this as it caps everything else, so counting and
  enumerating agree — `Enum.count(query)` and
  `length(Enum.to_list(query))` are the same number, reached by
  different routes.
  """
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{} = query) do
    matching = Zizq.count_jobs!(query.filters, query.client)

    case query.limit do
      nil -> matching
      limit -> min(matching, limit)
    end
  end

  @doc """
  The pages themselves, as a `Stream` of `Zizq.JobPage`.

  For when a page at a time is the useful unit — acknowledging in
  batches, say — rather than a flat run of jobs.
  """
  @spec pages(t()) :: Enumerable.t()
  def pages(%__MODULE__{} = query) do
    Stream.resource(
      fn -> :first end,
      fn
        :done ->
          {:halt, :done}

        :first ->
          page = Zizq.list_jobs!(request_opts(query), query.client)
          {[page], next_state(page)}

        {:next, page} ->
          case Zizq.next_page(page, query.client) do
            {:ok, nil} -> {:halt, :done}
            {:ok, next} -> {[next], next_state(next)}
            {:error, error} -> raise error
          end
      end,
      fn _ -> :ok end
    )
  end

  defp next_state(page) do
    if Zizq.JobPage.has_next?(page), do: {:next, page}, else: :done
  end

  # `:limit` caps the whole result, so it also caps a single request:
  # asking for more than the caller wants would fetch jobs only to
  # discard them.
  defp request_opts(%__MODULE__{} = query) do
    per_request = Enum.min(Enum.reject([query.page_size, query.limit], &is_nil/1) ++ [:none])

    query.filters
    |> put_unless_nil(:order, query.order)
    |> put_unless_nil(:limit, if(per_request == :none, do: nil, else: per_request))
  end

  defp put_unless_nil(opts, _key, nil), do: opts
  defp put_unless_nil(opts, key, value), do: Keyword.put(opts, key, value)

  @doc """
  Change every job the query matches, and return how many.

  Takes the options `Zizq.update_job/3` takes.

      Zizq.query(MyApp.Zizq)
      |> Zizq.Query.where(queue: "emails", status: :scheduled)
      |> Zizq.Query.update_all(ready_at: nil)

  One request, whatever the total — the server does the work from the
  filters. See "Working in batches" for when that is not what you
  want.
  """
  @spec update_all(t(), keyword()) :: non_neg_integer()
  def update_all(%__MODULE__{} = query, changes) do
    if batched?(query) do
      in_batches(query, fn scope ->
        Zizq.update_all_jobs!([where: scope, apply: changes], query.client)
      end)
    else
      Zizq.update_all_jobs!([where: query.filters, apply: changes], query.client)
    end
  end

  @doc """
  Delete every job the query matches, and return how many.

  One request by default. See "Working in batches".
  """
  @spec delete_all(t()) :: non_neg_integer()
  def delete_all(%__MODULE__{} = query) do
    if batched?(query) do
      in_batches(query, &Zizq.delete_all_jobs!(&1, query.client))
    else
      Zizq.delete_all_jobs!(query.filters, query.client)
    end
  end

  @doc """
  Bind every job the query matches to a budget.

  Jobs already bound to it are skipped over, so this does not conflict
  the way the single-job form does.

      Zizq.query(MyApp.Zizq)
      |> Zizq.Query.where(queue: "emails")
      |> Zizq.Query.bind_budget(key: "stripe", cost: 2)

  See also `Zizq.delete_budget/2`, which removes one outright.
  """
  @spec bind_budget(t(), Zizq.BudgetBinding.t() | keyword() | map()) :: Zizq.BudgetChange.t()
  def bind_budget(%__MODULE__{} = query, binding) do
    bang!(Zizq.bind_all_jobs_budget(binding, query.client, query.filters))
  end

  @doc """
  Bind every matching job to a budget, replacing any existing binding
  to it.

  The binding is replaced whole.
  """
  @spec rebind_budget(t(), Zizq.BudgetBinding.t() | keyword() | map()) :: Zizq.BudgetChange.t()
  def rebind_budget(%__MODULE__{} = query, binding) do
    bang!(Zizq.rebind_all_jobs_budget(binding, query.client, query.filters))
  end

  @doc """
  Change what an existing binding costs, leaving the binding alone.

  Matching jobs not bound to the budget are skipped over.
  """
  @spec set_budget_cost(t(), String.t(), pos_integer()) :: Zizq.BudgetChange.t()
  def set_budget_cost(%__MODULE__{} = query, key, cost) do
    bang!(Zizq.set_all_jobs_budget_cost(key, query.client, cost, query.filters))
  end

  @doc """
  Unbind one budget from every matching job, leaving their others
  alone.

  Paired with a `:budgets_key` filter this is how a budget can be
  drained before deletion:

      Zizq.query(MyApp.Zizq)
      |> Zizq.Query.where(budgets_key: "emails")
      |> Zizq.Query.unbind_budget("emails")

      Zizq.delete_budget("emails", MyApp.Zizq)
  """
  @spec unbind_budget(t(), String.t()) :: Zizq.BudgetChange.t()
  def unbind_budget(%__MODULE__{} = query, key) do
    bang!(Zizq.unbind_all_jobs_budget(key, query.client, query.filters))
  end

  @doc """
  Unbind *every* budget from every matching job.

  Beware: on an unfiltered query this strips every job in the server
  of its budgets.
  """
  @spec unbind_all_budgets(t()) :: Zizq.BudgetChange.t()
  def unbind_all_budgets(%__MODULE__{} = query) do
    bang!(Zizq.clear_all_jobs_budgets(query.filters, query.client))
  end

  # `Zizq.Query` raises rather than returning tuples — `update_all/2`
  # and `delete_all/1` already do, and a chain reads badly when one
  # link in it answers differently from the rest.
  defp bang!({:ok, change}), do: change
  defp bang!({:error, error}), do: raise(error)

  defp batched?(%__MODULE__{limit: limit, page_size: size}), do: limit != nil or size != nil

  # Walks the matching jobs a page at a time and acts on each page by
  # id, so ten million jobs become a run of bounded requests rather
  # than one that holds a lock over everything.
  #
  # The page's ids are sent *with* the original filters rather than
  # instead of them: an id is only a name, and a job that stopped
  # matching between being listed and being acted on should be left
  # alone.
  defp in_batches(%__MODULE__{} = query, fun) do
    query
    |> pages()
    |> Enum.reduce_while({0, query.limit}, fn page, {done, remaining} ->
      ids = page.jobs |> Enum.map(& &1.id) |> take_remaining(remaining)

      case ids do
        [] ->
          {:halt, {done, remaining}}

        ids ->
          affected = fun.(Keyword.put(query.filters, :id, ids))
          remaining = remaining && remaining - length(ids)

          if remaining && remaining <= 0 do
            {:halt, {done + affected, 0}}
          else
            {:cont, {done + affected, remaining}}
          end
      end
    end)
    |> elem(0)
  end

  defp take_remaining(ids, nil), do: ids
  defp take_remaining(ids, remaining), do: Enum.take(ids, remaining)

  defimpl Enumerable do
    def reduce(query, acc, fun) do
      query
      |> Zizq.Query.pages()
      |> Stream.flat_map(& &1.jobs)
      |> maybe_take(query.limit)
      |> Enumerable.reduce(acc, fun)
    end

    defp maybe_take(stream, nil), do: stream
    defp maybe_take(stream, limit), do: Stream.take(stream, limit)

    # Answered by the server rather than by walking the pages, so
    # counting a million jobs costs one request.
    def count(query), do: {:ok, Zizq.Query.count(query)}

    # Both would mean fetching everything to answer, which iterating
    # does anyway — so let `Enum` fall back to that.
    def member?(_query, _element), do: {:error, __MODULE__}
    def slice(_query), do: {:error, __MODULE__}
  end
end
