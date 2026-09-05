# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.BudgetBindingTest do
  @moduledoc """
  Binding a job to a budget, at enqueue and on a job module.

  A binding is the write side; what a job reports back is the read side
  and is deliberately narrower — a resolved `:cost` and no
  `:create_with`, which was an instruction about a budget rather than a
  property of the job.
  """

  use ExUnit.Case, async: true

  alias Zizq.BudgetBinding
  alias Zizq.Enqueue

  describe "new!/1" do
    test "builds from a keyword list" do
      binding = BudgetBinding.new!(key: "emails", cost: 2)

      assert binding.key == "emails"
      assert binding.cost == 2
      assert binding.create_with == nil
    end

    test ":cost is optional and defaults on the server" do
      assert BudgetBinding.new!(key: "emails").cost == nil
    end

    test "requires a key" do
      assert_raise ArgumentError, ~r/:key is required/, fn ->
        BudgetBinding.new!(cost: 2)
      end
    end

    test "rejects a zero or negative cost" do
      assert_raise ArgumentError, ~r/:cost must be a positive integer/, fn ->
        BudgetBinding.new!(key: "emails", cost: 0)
      end
    end

    test "rejects unknown keys" do
      assert_raise ArgumentError, ~r/unknown budget binding keys: \[:allocation\]/, fn ->
        BudgetBinding.new!(key: "emails", allocation: 100)
      end
    end
  end

  describe ":create_with" do
    # The key comes from the binding rather than being asked for twice.
    test "takes the policy without repeating the key" do
      binding =
        BudgetBinding.new!(
          key: "emails",
          create_with: [allocation: 100, strategy: :time_based, duration: :timer.minutes(1)]
        )

      assert binding.create_with.key == "emails"
      assert binding.create_with.duration == 60_000
    end

    # It is a whole `Zizq.Budget`, so it inherits that module's
    # validation rather than a second, looser copy of it.
    test "a clockless strategy still refuses a duration" do
      assert_raise ArgumentError, ~r/neither :duration nor :burst/, fn ->
        BudgetBinding.new!(
          key: "stripe",
          create_with: [allocation: 1, strategy: :while_in_flight, duration: 1_000]
        )
      end
    end

    test "accepts a budget struct, taking the binding's key" do
      policy = Zizq.Budget.new!(key: "ignored", allocation: 3, strategy: :while_in_flight)
      binding = BudgetBinding.new!(key: "stripe", create_with: policy)

      assert binding.create_with.key == "stripe"
    end
  end

  describe "wire form" do
    test "sends the key and cost" do
      assert BudgetBinding.to_wire(BudgetBinding.new!(key: "emails", cost: 2)) ==
               %{"key" => "emails", "cost" => 2}
    end

    test "omits an unset cost rather than sending null" do
      assert BudgetBinding.to_wire(BudgetBinding.new!(key: "emails")) == %{"key" => "emails"}
    end

    test "a create_with policy carries no key of its own" do
      binding =
        BudgetBinding.new!(
          key: "emails",
          create_with: [allocation: 100, strategy: :time_based, duration: 60_000]
        )

      assert BudgetBinding.to_wire(binding) == %{
               "key" => "emails",
               "create_with" => %{
                 "allocation" => 100,
                 "strategy" => %{"type" => "time_based", "duration_ms" => 60_000}
               }
             }
    end

    # A read is narrower than a write: the cost is resolved to what
    # applies, and `create_with` is not a property of the job.
    test "reads back a resolved binding" do
      binding = BudgetBinding.from_wire(%{"key" => "emails", "cost" => 2})

      assert binding == %BudgetBinding{key: "emails", cost: 2, create_with: nil}
    end
  end

  describe "on an enqueue" do
    test "binds at enqueue time" do
      enqueue = Enqueue.new!(type: "t", budgets: [[key: "emails", cost: 2]])

      assert [%BudgetBinding{key: "emails", cost: 2}] = enqueue.budgets
      assert Enqueue.to_wire(enqueue)["budgets"] == [%{"key" => "emails", "cost" => 2}]
    end

    test "accepts several budgets, all of which must be satisfied" do
      enqueue = Enqueue.new!(type: "t", budgets: [[key: "a"], [key: "b", cost: 3]])

      assert Enum.map(enqueue.budgets, & &1.key) == ["a", "b"]
    end

    # An unthrottled job pays nothing for the feature on the wire, which
    # is how the server reports one back too.
    test "an unthrottled job omits the field entirely" do
      refute Map.has_key?(Enqueue.to_wire(Enqueue.new!(type: "t")), "budgets")
      refute Map.has_key?(Enqueue.to_wire(Enqueue.new!(type: "t", budgets: [])), "budgets")
    end

    test "defaults to an empty list rather than nil" do
      assert Enqueue.new!(type: "t").budgets == []
    end

    test "a struct built by hand is normalised too" do
      enqueue = Enqueue.new!(%Enqueue{type: "t", budgets: [[key: "emails"]]})

      assert [%BudgetBinding{key: "emails"}] = enqueue.budgets
    end

    test "rejects something that is not a list" do
      assert_raise ArgumentError, ~r/:budgets must be a list/, fn ->
        Enqueue.new!(type: "t", budgets: %{key: "emails"})
      end
    end
  end

  describe "read back off a job" do
    test "a job reports what it draws on" do
      job =
        Zizq.Job.from_wire(%{
          "id" => "01K9",
          "type" => "t",
          "queue" => "q",
          "status" => "ready",
          "attempts" => 0,
          "budgets" => [%{"key" => "emails", "cost" => 2}]
        })

      assert [%BudgetBinding{key: "emails", cost: 2}] = job.budgets
    end

    # Worth reading back at all: a throttled job looks identical to a
    # stuck one from the outside.
    test "an unthrottled job reports none" do
      job =
        Zizq.Job.from_wire(%{
          "id" => "01K9",
          "type" => "t",
          "queue" => "q",
          "status" => "ready",
          "attempts" => 0
        })

      assert job.budgets == []
    end
  end

  describe "on a job module" do
    defmodule Throttled do
      use Zizq.JobKind,
        type: "throttled",
        queue: "emails",
        budgets: [[key: "emails", cost: 2]]

      @impl Zizq.JobKind
      def perform(_payload), do: :ok
    end

    test "the module's budgets ride on every enqueue" do
      assert [%BudgetBinding{key: "emails", cost: 2}] = Throttled.new(%{}).budgets
    end

    test "a per-enqueue value replaces them" do
      assert [%BudgetBinding{key: "other", cost: nil}] =
               Throttled.new(%{}, budgets: [[key: "other"]]).budgets
    end

    # `use Zizq.JobKind` evaluates its options while the module
    # compiles, so a malformed binding is a build failure rather than a
    # surprise at the first enqueue.
    test "a malformed binding fails the build" do
      assert_raise ArgumentError, ~r/unknown budget binding keys/, fn ->
        Code.eval_string("""
        defmodule Zizq.BudgetBindingTest.BadBinding do
          use Zizq.JobKind, type: "bad", budgets: [[key: "x", strategy: :time_based]]
          @impl Zizq.JobKind
          def perform(_), do: :ok
        end
        """)
      end
    end

    test "a malformed create_with policy fails the build" do
      assert_raise ArgumentError, ~r/requires a :duration/, fn ->
        Code.eval_string("""
        defmodule Zizq.BudgetBindingTest.BadPolicy do
          use Zizq.JobKind,
            type: "bad",
            budgets: [[key: "x", create_with: [allocation: 1, strategy: :time_based]]]

          @impl Zizq.JobKind
          def perform(_), do: :ok
        end
        """)
      end
    end
  end
end
