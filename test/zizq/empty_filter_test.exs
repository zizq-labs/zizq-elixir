# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.EmptyFilterTest do
  @moduledoc """
  A set filter given an empty list selects no jobs.

  Omitting it from the query string would select *every* job, so the
  two must not be confused. This is not a theoretical distinction: the
  list is usually computed, and `queue: Enum.filter(...)` coming back
  empty has to delete nothing rather than everything.

  Every filtered operation therefore answers its own zero without
  sending a request, which is what these tests pin — `refute_receive`
  is the assertion that matters in each.
  """

  use ExUnit.Case, async: true

  alias Zizq.BudgetChange
  alias Zizq.FakeServer
  alias Zizq.Filter
  alias Zizq.Query

  # Answers plausibly to anything, so a test that reaches the network
  # fails on the unexpected request rather than on a decoding error.
  defp server do
    test_pid = self()

    FakeServer.start_client!(
      fn conn ->
        {:ok, _raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, conn.method, conn.request_path})

        body =
          JSON.encode!(%{
            "jobs" => [],
            "pages" => %{},
            "count" => 99,
            "deleted" => 99,
            "patched" => 99,
            "changed" => 99,
            "blocked" => []
          })

        FakeServer.respond(conn, 200, "application/json", body)
      end,
      format: :json
    )
  end

  describe "matches_nothing?/1" do
    test "an empty list matches nothing" do
      assert Filter.matches_nothing?(queue: [])
      assert Filter.matches_nothing?(id: [])
      assert Filter.matches_nothing?(budgets_key: [])
    end

    # It encodes to the same absent parameter, so it means the same.
    test "an empty string matches nothing" do
      assert Filter.matches_nothing?(queue: "")
    end

    test "one empty set is enough, whatever else narrows" do
      assert Filter.matches_nothing?(id: [], status: :ready, queue: "emails")
    end

    # An absent filter does not narrow; it is not the same as an empty
    # one, and must not short-circuit.
    test "no filters at all matches everything" do
      refute Filter.matches_nothing?([])
      refute Filter.matches_nothing?(queue: nil)
      refute Filter.matches_nothing?(status: :ready)
      refute Filter.matches_nothing?(queue: ["a"])
      refute Filter.matches_nothing?(priority: 5)
    end
  end

  describe "reads" do
    test "list_jobs answers an empty page" do
      name = server()

      assert {:ok, %Zizq.JobPage{jobs: []}} = Zizq.list_jobs([queue: []], name)
      refute_receive {:request, _, _}
    end

    test "count_jobs answers zero" do
      name = server()

      assert {:ok, 0} = Zizq.count_jobs([queue: []], name)
      refute_receive {:request, _, _}
    end
  end

  describe "destructive operations" do
    # The one that matters most: without the guard this deletes every
    # job on the server.
    test "delete_all_jobs deletes nothing" do
      name = server()

      assert {:ok, 0} = Zizq.delete_all_jobs([queue: []], name)
      refute_receive {:request, _, _}
    end

    test "update_all_jobs changes nothing" do
      name = server()

      assert {:ok, 0} =
               Zizq.update_all_jobs([where: [id: []], apply: [queue: "elsewhere"]], name)

      refute_receive {:request, _, _}
    end

    test "an unfiltered delete still reaches the server" do
      name = server()

      assert {:ok, 99} = Zizq.delete_all_jobs([], name)
      assert_receive {:request, "DELETE", "/jobs"}
    end
  end

  describe "budget bindings" do
    test "binding touches nothing" do
      name = server()

      assert {:ok, %BudgetChange{changed: 0, blocked: []}} =
               Zizq.bind_all_jobs_budget([key: "emails"], [queue: []], name)

      refute_receive {:request, _, _}
    end

    # Without the guard this unthrottles every queued job on the server.
    test "unbinding every budget touches nothing" do
      name = server()

      assert {:ok, %BudgetChange{changed: 0}} =
               Zizq.unbind_all_jobs_budgets([budgets_key: []], name)

      refute_receive {:request, _, _}
    end

    test "the query form short-circuits too" do
      name = server()

      change =
        Zizq.query(name) |> Query.where(queue: []) |> Query.unbind_budget("emails")

      assert change == %BudgetChange{changed: 0, blocked: []}
      refute_receive {:request, _, _}
    end
  end
end
