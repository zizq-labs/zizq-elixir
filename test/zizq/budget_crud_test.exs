# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.BudgetCrudTest do
  @moduledoc """
  Defining, reading, amending and deleting budgets.

  `update_budget/3` gets most of the attention: it is JSON merge patch
  and recurses into the strategy, so an absent option, `nil` and a
  value are three different instructions. `:burst` is the only field
  where `nil` means anything, and sending it where it was not asked for
  silently clears a ceiling.
  """

  use ExUnit.Case, async: true

  alias Zizq.Budget
  alias Zizq.FakeServer

  defp budget_body(overrides \\ %{}) do
    %{
      "key" => "emails",
      "allocation" => 100,
      "strategy" => %{"type" => "time_based", "duration_ms" => 60_000},
      "created_at" => 1_700_000_000_000
    }
    |> Map.merge(overrides)
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

  describe "list_budgets/1" do
    test "returns every budget" do
      name = server(200, JSON.encode!(%{"budgets" => [JSON.decode!(budget_body())]}))

      assert {:ok, [%Budget{key: "emails", allocation: 100}]} = Zizq.list_budgets(name)
      assert_receive {:request, "GET", "/budgets", nil}
    end

    test "an absent list reads as empty" do
      name = server(200, JSON.encode!(%{}))
      assert {:ok, []} = Zizq.list_budgets(name)
    end

    # Budgets are Pro-gated, and the message is what says which feature
    # was refused.
    test "surfaces a licence refusal as :forbidden" do
      name = server(403, error_body("budgets require a Pro license"))

      assert {:error, %Zizq.Error{reason: :forbidden, message: message}} =
               Zizq.list_budgets(name)

      assert message =~ "Pro license"
    end
  end

  describe "get_budget/2" do
    test "returns the policy in milliseconds" do
      name = server(200, budget_body())

      assert {:ok, budget} = Zizq.get_budget("emails", name)
      assert budget.duration == 60_000
      assert budget.created_at == DateTime.from_unix!(1_700_000_000_000, :millisecond)
      assert_receive {:request, "GET", "/budgets/emails", nil}
    end

    test "takes a budget as well as a key" do
      name = server(200, budget_body())
      budget = Budget.new!(key: "emails", allocation: 1, strategy: :while_in_flight)

      assert {:ok, _} = Zizq.get_budget(budget, name)
      assert_receive {:request, "GET", "/budgets/emails", nil}
    end

    test "a missing budget is :not_found" do
      name = server(404, error_body("budget not found"))
      assert {:error, %Zizq.Error{reason: :not_found}} = Zizq.get_budget("nope", name)
    end

    test "the bang variant raises" do
      name = server(404, error_body("budget not found"))
      assert_raise Zizq.Error, fn -> Zizq.get_budget!("nope", name) end
    end
  end

  describe "define_budget/3" do
    test "POSTs the policy with its period in milliseconds" do
      name = server(201, budget_body())

      budget =
        Budget.new!(
          key: "emails",
          allocation: 100,
          strategy: :time_based,
          duration: :timer.minutes(1)
        )

      assert {:ok, %Budget{}} = Zizq.define_budget(budget, name)

      assert_receive {:request, "POST", "/budgets/emails", body}

      assert body == %{
               "allocation" => 100,
               "strategy" => %{"type" => "time_based", "duration_ms" => 60_000}
             }
    end

    test "accepts a keyword list instead of a struct" do
      name = server(201, budget_body())

      assert {:ok, %Budget{}} =
               Zizq.define_budget(
                 [key: "stripe", allocation: 3, strategy: :while_in_flight],
                 name
               )

      assert_receive {:request, "POST", "/budgets/stripe", body}
      assert body["strategy"] == %{"type" => "while_in_flight"}
    end

    # `POST` refuses rather than overwriting, which is what lets every
    # node declare its budgets on boot without coordinating.
    test "a second definition conflicts" do
      name = server(409, error_body("budget 'emails' already exists"))

      assert {:error, %Zizq.Error{reason: :conflict}} =
               Zizq.define_budget(
                 [key: "emails", allocation: 1, strategy: :while_in_flight],
                 name
               )
    end

    test ":replace switches to PUT and never conflicts" do
      name = server(200, budget_body())

      assert {:ok, %Budget{}} =
               Zizq.define_budget(
                 [key: "emails", allocation: 200, strategy: :while_in_flight],
                 name,
                 replace: true
               )

      assert_receive {:request, "PUT", "/budgets/emails", %{"allocation" => 200}}
    end

    # Validation happens before anything is sent, so a malformed budget
    # never reaches the server.
    test "an invalid budget raises without a request" do
      name = server(201, budget_body())

      assert_raise ArgumentError, ~r/requires a :duration/, fn ->
        Zizq.define_budget([key: "a", allocation: 1, strategy: :time_based], name)
      end

      refute_receive {:request, _, _, _}
    end
  end

  describe "update_budget/3" do
    test "sends only the field that was named" do
      name = server(200, budget_body())

      assert {:ok, %Budget{}} = Zizq.update_budget("emails", name, burst: 5)

      assert_receive {:request, "PATCH", "/budgets/emails", body}
      assert body == %{"strategy" => %{"burst" => 5}}
    end

    test "an explicit nil burst clears the ceiling" do
      name = server(200, budget_body())

      assert {:ok, %Budget{}} = Zizq.update_budget("emails", name, burst: nil)

      assert_receive {:request, "PATCH", "/budgets/emails", body}
      assert body == %{"strategy" => %{"burst" => nil}}
    end

    test "the period is sent in milliseconds" do
      name = server(200, budget_body())

      assert {:ok, %Budget{}} =
               Zizq.update_budget("emails", name, duration: :timer.seconds(30))

      assert_receive {:request, "PATCH", "/budgets/emails", body}
      assert body == %{"strategy" => %{"duration_ms" => 30_000}}
    end

    test "the allocation sits outside the strategy" do
      name = server(200, budget_body())

      assert {:ok, %Budget{}} = Zizq.update_budget("emails", name, allocation: 50)

      assert_receive {:request, "PATCH", "/budgets/emails", %{"allocation" => 50}}
    end

    test "changes the kind and period together" do
      name = server(200, budget_body())

      assert {:ok, %Budget{}} =
               Zizq.update_budget("emails", name, strategy: :time_based, duration: 1_000)

      assert_receive {:request, "PATCH", "/budgets/emails", body}
      assert body["strategy"] == %{"type" => "time_based", "duration_ms" => 1_000}
    end

    # A patch has nothing to merge into, so unlike `:replace` it does
    # not create the budget.
    test "a missing budget is :not_found" do
      name = server(404, error_body("budget not found"))

      assert {:error, %Zizq.Error{reason: :not_found}} =
               Zizq.update_budget("nope", name, burst: 1)
    end

    test "an empty patch raises rather than sending nothing" do
      name = server(200, budget_body())

      assert_raise ArgumentError, ~r/at least one field/, fn ->
        Zizq.update_budget("emails", name, [])
      end

      refute_receive {:request, _, _, _}
    end

    test "rejects unknown keys" do
      name = server(200, budget_body())

      assert_raise ArgumentError, ~r/unknown budget keys/, fn ->
        Zizq.update_budget("emails", name, duration_ms: 1_000)
      end
    end
  end

  describe "delete_budget/2" do
    test "deletes and answers :ok" do
      name = server(204, nil)

      assert :ok = Zizq.delete_budget("emails", name)
      assert_receive {:request, "DELETE", "/budgets/emails", nil}
    end

    # Refused while anything still draws on it; the message names which
    # of the two remedies applies.
    test "is refused while still referenced" do
      name = server(409, error_body("budget 'emails' is referenced by 3 unfinished jobs."))

      assert {:error, %Zizq.Error{reason: :conflict, message: message}} =
               Zizq.delete_budget("emails", name)

      assert message =~ "unfinished jobs"
    end

    test "the bang variant raises" do
      name = server(409, error_body("still referenced"))
      assert_raise Zizq.Error, fn -> Zizq.delete_budget!("emails", name) end
    end
  end
end
