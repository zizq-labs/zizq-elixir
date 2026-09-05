# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.BudgetJobTest do
  @moduledoc """
  Changing what one job draws on, after it has been enqueued.

  These are the operator-facing half of budgets: splitting one shared
  budget in two, or lifting a throttle off a single stuck job, without
  rewriting the enqueue that produced it.

  Each answers the updated job rather than `:ok`, so its `:budgets`
  reflect the change without a second read.
  """

  use ExUnit.Case, async: true

  alias Zizq.BudgetBinding
  alias Zizq.FakeServer

  defp job_body(budgets \\ []) do
    %{
      "id" => "01K9",
      "type" => "send_email",
      "queue" => "emails",
      "status" => "ready",
      "attempts" => 0
    }
    |> then(fn job -> if budgets == [], do: job, else: Map.put(job, "budgets", budgets) end)
    |> JSON.encode!()
  end

  defp server(status, body) do
    test_pid = self()

    FakeServer.start_client!(
      fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        decoded = if raw == "", do: nil, else: JSON.decode!(raw)
        send(test_pid, {:request, conn.method, conn.request_path, decoded})

        FakeServer.respond(conn, status, if(body, do: "application/json"), body || "")
      end,
      format: :json
    )
  end

  defp error_body(message), do: JSON.encode!(%{"error" => message})

  describe "bind_budget/3" do
    test "binds and answers the updated job" do
      name = server(200, job_body([%{"key" => "emails", "cost" => 2}]))

      assert {:ok, job} = Zizq.bind_budget("01K9", name, key: "emails", cost: 2)
      assert [%BudgetBinding{key: "emails", cost: 2}] = job.budgets

      assert_receive {:request, "POST", "/jobs/01K9/budgets/emails", body}
      # The key travels in the path, so the body carries only the rest.
      assert body == %{"cost" => 2}
    end

    test "takes a job struct as well as an id" do
      name = server(200, job_body())

      assert {:ok, _} = Zizq.bind_budget(%Zizq.Job{id: "01K9"}, name, key: "emails")
      assert_receive {:request, "POST", "/jobs/01K9/budgets/emails", %{}}
    end

    test "carries a create_with policy" do
      name = server(200, job_body())

      Zizq.bind_budget("01K9", name,
        key: "emails",
        create_with: [allocation: 100, strategy: :time_based, duration: :timer.minutes(1)]
      )

      assert_receive {:request, "POST", "/jobs/01K9/budgets/emails", body}

      assert body["create_with"] == %{
               "allocation" => 100,
               "strategy" => %{"type" => "time_based", "duration_ms" => 60_000}
             }
    end

    # `POST` refuses rather than replacing, so an existing binding and
    # its cost survive a careless re-bind.
    test "conflicts when already bound" do
      name = server(409, error_body("job '01K9' already draws on budget 'emails'"))

      assert {:error, %Zizq.Error{reason: :conflict}} =
               Zizq.bind_budget("01K9", name, key: "emails")
    end

    # Only queued jobs can be rebound: an in-flight one already holds
    # tokens against its budgets.
    test "refuses a job that is not queued" do
      name = server(422, error_body("job '01K9' is InFlight — only queued jobs may change"))

      assert {:error, %Zizq.Error{reason: :invalid_request}} =
               Zizq.bind_budget("01K9", name, key: "emails")
    end
  end

  describe "rebind_budget/3" do
    test "replaces the binding whole" do
      name = server(200, job_body([%{"key" => "emails", "cost" => 1}]))

      assert {:ok, _} = Zizq.rebind_budget("01K9", name, key: "emails")

      assert_receive {:request, "PUT", "/jobs/01K9/budgets/emails", body}
      # An unset cost returns to the default rather than being kept.
      assert body == %{}
    end
  end

  describe "set_budget_cost/4" do
    test "patches only the cost" do
      name = server(200, job_body([%{"key" => "emails", "cost" => 5}]))

      assert {:ok, job} = Zizq.set_budget_cost("01K9", name, "emails", 5)
      assert [%BudgetBinding{cost: 5}] = job.budgets

      assert_receive {:request, "PATCH", "/jobs/01K9/budgets/emails", %{"cost" => 5}}
    end

    # A change of cost has nothing to apply to when the job is not
    # bound, so unlike `rebind_budget/3` it does not create the binding.
    test "is :not_found when the job does not draw on it" do
      name = server(404, error_body("job '01K9' does not draw on budget 'emails'"))

      assert {:error, %Zizq.Error{reason: :not_found}} =
               Zizq.set_budget_cost("01K9", name, "emails", 5)
    end

    test "refuses a non-positive cost before sending" do
      name = server(200, job_body())

      assert_raise FunctionClauseError, fn ->
        Zizq.set_budget_cost("01K9", name, "emails", 0)
      end

      refute_receive {:request, _, _, _}
    end
  end

  describe "unbind_budget/3" do
    test "unbinds one, leaving the others" do
      name = server(200, job_body([%{"key" => "stripe", "cost" => 1}]))

      assert {:ok, job} = Zizq.unbind_budget("01K9", name, "emails")
      assert [%BudgetBinding{key: "stripe"}] = job.budgets

      assert_receive {:request, "DELETE", "/jobs/01K9/budgets/emails", nil}
    end

    test "is :not_found when the job does not draw on it" do
      name = server(404, error_body("job '01K9' does not draw on budget 'emails'"))

      assert {:error, %Zizq.Error{reason: :not_found}} =
               Zizq.unbind_budget("01K9", name, "emails")
    end
  end

  describe "unbind_all_budgets/2" do
    # The server omits `budgets` for an unthrottled job rather than
    # sending an empty array, so the job reads back with none.
    test "leaves the job unthrottled" do
      name = server(200, job_body())

      assert {:ok, job} = Zizq.unbind_all_budgets("01K9", name)
      assert job.budgets == []

      assert_receive {:request, "DELETE", "/jobs/01K9/budgets", nil}
    end
  end

  describe "replace_budgets/3" do
    test "describes the whole set outright" do
      name = server(200, job_body([%{"key" => "a", "cost" => 1}, %{"key" => "b", "cost" => 3}]))

      assert {:ok, job} =
               Zizq.replace_budgets("01K9", name, [[key: "a"], [key: "b", cost: 3]])

      assert Enum.map(job.budgets, & &1.key) == ["a", "b"]

      assert_receive {:request, "PUT", "/jobs/01K9/budgets", body}
      assert body == %{"budgets" => [%{"key" => "a"}, %{"key" => "b", "cost" => 3}]}
    end

    test "an empty list unbinds everything" do
      name = server(200, job_body())

      assert {:ok, %Zizq.Job{budgets: []}} = Zizq.replace_budgets("01K9", name, [])
      assert_receive {:request, "PUT", "/jobs/01K9/budgets", %{"budgets" => []}}
    end

    # Validation happens before anything is sent.
    test "a malformed binding raises without a request" do
      name = server(200, job_body())

      assert_raise ArgumentError, ~r/:key is required/, fn ->
        Zizq.replace_budgets("01K9", name, [[cost: 2]])
      end

      refute_receive {:request, _, _, _}
    end
  end
end
