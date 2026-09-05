# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.BudgetQueryTest do
  @moduledoc """
  Selecting jobs by the budgets they draw on, and rebinding a selection
  in bulk.

  The filter and the bulk operations are the same feature seen from two
  ends: `:budgets_key` finds what is holding a budget in use, and
  `unbind_budget/2` is what clears it so the budget can be deleted.
  """

  use ExUnit.Case, async: true

  alias Zizq.BudgetChange
  alias Zizq.FakeServer
  alias Zizq.Filter
  alias Zizq.Query

  defp server(status, body) do
    test_pid = self()

    FakeServer.start_client!(
      fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        decoded = if raw == "", do: nil, else: JSON.decode!(raw)
        send(test_pid, {:request, conn.method, conn.request_path, conn.query_string, decoded})

        FakeServer.respond(conn, status, if(body, do: "application/json"), body || "")
      end,
      format: :json
    )
  end

  defp change_body(changed, blocked \\ []) do
    JSON.encode!(%{"changed" => changed, "blocked" => blocked})
  end

  describe "the :budgets_key filter" do
    # Dotted on the wire, mirroring the `budgets` array on a job. Not a
    # writable Elixir keyword, hence the underscore in the option.
    test "is sent as budgets.key" do
      assert Filter.to_params(budgets_key: "emails") == ["budgets.key": "emails"]
    end

    test "takes a list, matching any of them" do
      assert Filter.to_params(budgets_key: ["emails", "stripe"]) ==
               ["budgets.key": "emails,stripe"]
    end

    test "rejects a value containing a comma" do
      assert_raise ArgumentError, ~r/cannot contain a comma/, fn ->
        Filter.to_params(budgets_key: "a,b")
      end
    end

    test "narrows a listing" do
      name = server(200, JSON.encode!(%{"jobs" => [], "pages" => %{}}))

      Zizq.list_jobs!([budgets_key: "emails"], name)

      assert_receive {:request, "GET", "/jobs", query, nil}
      assert query =~ "budgets.key=emails"
    end

    test "narrows a count" do
      name = server(200, JSON.encode!(%{"count" => 3}))

      assert Zizq.count_jobs!([budgets_key: "emails"], name) == 3
      assert_receive {:request, "GET", "/jobs/count", query, nil}
      assert query =~ "budgets.key=emails"
    end
  end

  describe "bind_budget/2" do
    test "binds the selection and reports what changed" do
      name = server(200, change_body(4))

      change =
        Zizq.query(name)
        |> Query.where(queue: "emails")
        |> Query.bind_budget(key: "stripe", cost: 2)

      assert change == %BudgetChange{changed: 4, blocked: []}
      assert BudgetChange.complete?(change)

      assert_receive {:request, "POST", "/jobs/budgets/stripe", query, body}
      assert query =~ "queue=emails"
      # The key travels in the path, so the body carries only the rest.
      assert body == %{"cost" => 2}
    end

    test "carries a create_with policy" do
      name = server(200, change_body(1))

      Zizq.query(name)
      |> Query.bind_budget(
        key: "stripe",
        create_with: [allocation: 3, strategy: :while_in_flight]
      )

      assert_receive {:request, "POST", "/jobs/budgets/stripe", _query, body}

      assert body["create_with"] == %{
               "allocation" => 3,
               "strategy" => %{"type" => "while_in_flight"}
             }
    end

    # Only queued jobs can be rebound, and the ones that could not are
    # named rather than silently skipped.
    test "reports jobs that were in flight" do
      name = server(200, change_body(2, ["01K9", "01KA"]))

      change = Zizq.query(name) |> Query.bind_budget(key: "stripe")

      assert change == %BudgetChange{changed: 2, blocked: ["01K9", "01KA"]}
      refute BudgetChange.complete?(change)
    end
  end

  describe "rebind_budget/2" do
    test "replaces the binding whole" do
      name = server(200, change_body(1))

      Zizq.query(name) |> Query.where(queue: "emails") |> Query.rebind_budget(key: "stripe")

      assert_receive {:request, "PUT", "/jobs/budgets/stripe", query, body}
      assert query =~ "queue=emails"
      # An unset cost returns to the default rather than being kept.
      assert body == %{}
    end
  end

  describe "set_budget_cost/3" do
    test "patches the cost across the selection" do
      name = server(200, change_body(3))

      Zizq.query(name) |> Query.where(status: :ready) |> Query.set_budget_cost("stripe", 5)

      assert_receive {:request, "PATCH", "/jobs/budgets/stripe", query, body}
      assert query =~ "status=ready"
      assert body == %{"cost" => 5}
    end
  end

  describe "unbind_budget/2" do
    # The pairing the filter exists for: find what holds the budget,
    # clear it, then the budget can be deleted.
    test "drains a budget by what draws on it" do
      name = server(200, change_body(12))

      change =
        Zizq.query(name)
        |> Query.where(budgets_key: "emails")
        |> Query.unbind_budget("emails")

      assert change.changed == 12
      assert_receive {:request, "DELETE", "/jobs/budgets/emails", query, nil}
      assert query =~ "budgets.key=emails"
    end
  end

  describe "unbind_all_budgets/1" do
    test "clears every budget from the selection" do
      name = server(200, change_body(9))

      assert %BudgetChange{changed: 9} =
               Zizq.query(name) |> Query.where(queue: "emails") |> Query.unbind_all_budgets()

      assert_receive {:request, "DELETE", "/jobs/budgets", query, nil}
      assert query =~ "queue=emails"
    end
  end

  describe "failures" do
    # A chain raises rather than returning tuples, as `update_all/2`
    # and `delete_all/1` already do.
    test "the query form raises" do
      name = server(403, JSON.encode!(%{"error" => "budgets require a Pro license"}))

      assert_raise Zizq.Error, ~r/Pro license/, fn ->
        Zizq.query(name) |> Query.bind_budget(key: "stripe")
      end
    end

    test "the module form answers a tuple" do
      name = server(403, JSON.encode!(%{"error" => "budgets require a Pro license"}))

      assert {:error, %Zizq.Error{reason: :forbidden}} =
               Zizq.bind_all_jobs_budget([key: "stripe"], name, [])
    end

    # Validation happens before anything is sent.
    test "a malformed binding raises without a request" do
      name = server(200, change_body(0))

      assert_raise ArgumentError, ~r/:key is required/, fn ->
        Zizq.query(name) |> Query.bind_budget(cost: 2)
      end

      refute_receive {:request, _, _, _, _}
    end
  end
end
