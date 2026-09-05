# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Filter do
  @moduledoc """
  Filters shared by every endpoint that selects jobs.

  `Zizq.list_jobs/2`, `Zizq.count_jobs/2` and the bulk operations all
  narrow the same way, so the vocabulary is described once here.

      Zizq.count_jobs([queue: "emails", status: [:ready, :scheduled]], MyApp.Zizq)

  ## Options

    * `:id` — one job id, or a list of them.
    * `:queue` — one queue name, or a list.
    * `:type` — one job type, or a list.
    * `:status` — one status atom, or a list.
    * `:budgets_key` — one budget key, or a list. Matches a job bound
      to any of them.
    * `:priority` — a number, a `Range`, or `[min: _, max: _]`.
    * `:ready_at` — the same, over `DateTime`s or milliseconds.
    * `:attempts` — the same, over attempt counts.
    * `:filter` — a jq expression run against each payload, e.g.
      `".user_id == 42"`.

  An option left out does not narrow anything. A list matches any of
  its members, so `status: [:ready, :scheduled]` finds jobs in either.

  ## Ranges

  Ranges are inclusive at both ends. A bare number matches exactly:

      priority: 5           # exactly 5
      priority: 1..10       # 1 to 10
      priority: [min: 5]    # 5 and above
      priority: [max: 5]    # 5 and below

  `:ready_at` accepts `DateTime`s as well as milliseconds, so a window
  reads as one:

      ready_at: [min: DateTime.utc_now()]

  ## Budgets

  `:budgets_key` selects by what a job is bound to, which is useful
  for finding what is holding a budget in use — `Zizq.delete_budget/2`
  refuses while anything remains bound:

      Zizq.query(MyApp.Zizq)
      |> Zizq.Query.where(budgets_key: "emails")
      |> Zizq.Query.unbind_budget("emails")
  """

  @sets [:id, :queue, :type, :status, :budgets_key]
  @ranges [:priority, :ready_at, :attempts]
  @keys @sets ++ @ranges ++ [:filter]

  @doc """
  Whether these filters can match nothing at all.

  A set filter given an empty list selects no jobs, but omitting it
  from the query string would select *every* job — so the two must not
  be confused. Callers check this and answer their own zero rather than
  sending a request:

      Zizq.delete_all_jobs([queue: []], MyApp.Zizq)   # => {:ok, 0}

  This matters most where the list is computed. `queue: Enum.filter(...)`
  coming back empty must delete nothing, not everything.

  An empty string counts the same way, since it encodes to the same
  absent parameter.
  """
  @spec matches_nothing?(keyword() | map()) :: boolean()
  def matches_nothing?(filters) do
    Enum.any?(filters, fn {key, value} ->
      key in @sets and not is_nil(value) and is_nil(encode(key, value))
    end)
  end

  @doc false
  # Encoded as query parameters rather than a body: these are GET
  # endpoints, and the bulk operations take the same selection in their
  # query string so that what is being changed reads the same way as
  # what is being listed.
  @spec to_params(keyword() | map()) :: keyword()
  def to_params(filters) do
    filters = Map.new(filters)

    case Map.keys(filters) -- @keys do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown filter#{if length(unknown) > 1, do: "s"}: #{inspect(unknown)}. " <>
                "Known filters are #{inspect(@keys)}"
    end

    filters
    |> Enum.map(fn {key, value} -> {param(key), encode(key, value)} end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  # The server spells this one with a dot, mirroring the `budgets`
  # array on a job rather than inventing a second name for the same
  # thing. `budgets.key` is not a writable Elixir keyword, so the
  # option is `:budgets_key` and the rename happens here.
  defp param(:budgets_key), do: :"budgets.key"
  defp param(key), do: key

  defp encode(_key, nil), do: nil

  # Comma-delimited, which is why a value cannot contain one. The
  # server would read "a,b" as two names, so this fails here instead of
  # quietly matching something else.
  defp encode(key, value) when key in @sets do
    value
    |> List.wrap()
    |> Enum.map(&set_member!(key, &1))
    |> Enum.join(",")
    |> case do
      "" -> nil
      encoded -> encoded
    end
  end

  defp encode(key, value) when key in @ranges, do: range!(key, value)
  defp encode(:filter, value) when is_binary(value), do: value

  defp encode(:filter, value) do
    raise ArgumentError, "filter :filter must be a jq expression string, got #{inspect(value)}"
  end

  defp set_member!(_key, value) when is_atom(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp set_member!(key, value) when is_binary(value) do
    if String.contains?(value, ",") do
      raise ArgumentError,
            "filter :#{key} values cannot contain a comma — to provide " <>
              "multiple values use a list: #{inspect(value)}"
    end

    value
  end

  defp set_member!(key, value) do
    raise ArgumentError, "filter :#{key} must be a string or atom, got #{inspect(value)}"
  end

  defp range!(_key, value) when is_integer(value), do: Integer.to_string(value)

  defp range!(key, %Range{first: first, last: last, step: step}) do
    if step != 1 do
      raise ArgumentError, "filter :#{key} cannot take a stepped range"
    end

    "#{bound!(key, first)}..#{bound!(key, last)}"
  end

  defp range!(key, %DateTime{} = at), do: bound!(key, at)

  defp range!(key, bounds) when is_list(bounds) or is_map(bounds) do
    bounds = Map.new(bounds)

    case Map.keys(bounds) -- [:min, :max] do
      [] ->
        :ok

      unknown ->
        raise ArgumentError, "filter :#{key} takes :min and :max, got #{inspect(unknown)}"
    end

    min = bounds |> Map.get(:min) |> then(&bound!(key, &1))
    max = bounds |> Map.get(:max) |> then(&bound!(key, &1))

    if min == "" and max == "" do
      raise ArgumentError, "filter :#{key} needs at least one of :min and :max"
    end

    "#{min}..#{max}"
  end

  defp range!(key, value) do
    raise ArgumentError,
          "filter :#{key} must be a number, a Range, or [min: _, max: _], got #{inspect(value)}"
  end

  # An absent bound is an empty string, which is how the server spells
  # an open end: `..10`, `5..`.
  defp bound!(_key, nil), do: ""
  defp bound!(_key, value) when is_integer(value), do: Integer.to_string(value)

  defp bound!(:ready_at, %DateTime{} = at),
    do: at |> Zizq.Timestamp.to_ms() |> Integer.to_string()

  defp bound!(key, value) do
    raise ArgumentError, "filter :#{key} bounds must be integers, got #{inspect(value)}"
  end
end
