# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.BudgetTest do
  @moduledoc """
  The budget struct and its wire form.

  The validation here is deliberately strict about the strategy: the
  server parses the tag by hand rather than using a tagged enum,
  precisely so a `:duration` on a clockless budget is refused instead of
  silently dropped. The client refuses it a step earlier.
  """

  use ExUnit.Case, async: true

  alias Zizq.Budget

  describe "new!/1" do
    test "builds a rate limit" do
      budget =
        Budget.new!(
          key: "emails",
          allocation: 100,
          strategy: :time_based,
          duration: :timer.minutes(1)
        )

      assert budget.key == "emails"
      assert budget.allocation == 100
      assert budget.duration == 60_000
      assert budget.burst == nil
      assert Budget.time_based?(budget)
      refute Budget.while_in_flight?(budget)
    end

    test "builds a concurrency limit" do
      budget = Budget.new!(key: "stripe", allocation: 3, strategy: :while_in_flight)

      assert budget.duration == nil
      assert Budget.while_in_flight?(budget)
    end

    test "accepts a map as well as a keyword list" do
      assert Budget.new!(%{key: "a", allocation: 1, strategy: :while_in_flight}) ==
               Budget.new!(key: "a", allocation: 1, strategy: :while_in_flight)
    end

    test "passes a struct through unchanged" do
      budget = Budget.new!(key: "a", allocation: 1, strategy: :while_in_flight)
      assert Budget.new!(budget) == budget
    end

    test ":time_based requires a duration" do
      assert_raise ArgumentError, ~r/requires a :duration/, fn ->
        Budget.new!(key: "emails", allocation: 100, strategy: :time_based)
      end
    end

    # Refused rather than ignored: a budget that reads as though it set a
    # refill period but did not is worse than one that fails to build.
    test ":while_in_flight refuses a duration" do
      assert_raise ArgumentError, ~r/neither :duration nor :burst/, fn ->
        Budget.new!(
          key: "stripe",
          allocation: 1,
          strategy: :while_in_flight,
          duration: :timer.minutes(1)
        )
      end
    end

    test ":while_in_flight refuses a burst" do
      assert_raise ArgumentError, ~r/neither :duration nor :burst/, fn ->
        Budget.new!(key: "stripe", allocation: 1, strategy: :while_in_flight, burst: 5)
      end
    end

    test "rejects an unknown strategy" do
      assert_raise ArgumentError, ~r/:strategy must be one of/, fn ->
        Budget.new!(key: "a", allocation: 1, strategy: :sliding_window)
      end
    end

    test "rejects unknown keys" do
      assert_raise ArgumentError, ~r/unknown budget keys: \[:duration_ms\]/, fn ->
        Budget.new!(key: "a", allocation: 1, strategy: :time_based, duration_ms: 60_000)
      end
    end

    # The server assigns these; a definition does not get to claim them.
    test "rejects server-assigned timestamps" do
      assert_raise ArgumentError, ~r/unknown budget keys/, fn ->
        Budget.new!(
          key: "a",
          allocation: 1,
          strategy: :while_in_flight,
          created_at: DateTime.utc_now()
        )
      end
    end

    test "requires a key" do
      assert_raise ArgumentError, ~r/:key is required/, fn ->
        Budget.new!(allocation: 1, strategy: :while_in_flight)
      end
    end

    test "requires a positive allocation" do
      assert_raise ArgumentError, ~r/:allocation must be a positive integer/, fn ->
        Budget.new!(key: "a", allocation: 0, strategy: :while_in_flight)
      end
    end
  end

  describe "capacity/1" do
    test "is the allocation when no burst is set" do
      budget =
        Budget.new!(key: "a", allocation: 100, strategy: :time_based, duration: 60_000)

      assert Budget.capacity(budget) == 100
    end

    # Worth distinguishing from the allocation: with a burst set it is
    # the smaller number that decides what can ever be afforded.
    test "is the burst when one is set" do
      budget =
        Budget.new!(
          key: "a",
          allocation: 100,
          strategy: :time_based,
          duration: 60_000,
          burst: 5
        )

      assert Budget.capacity(budget) == 5
    end
  end

  describe "wire form" do
    test "a rate limit sends its period in milliseconds" do
      budget =
        Budget.new!(
          key: "emails",
          allocation: 100,
          strategy: :time_based,
          duration: :timer.minutes(1),
          burst: 5
        )

      assert Budget.to_wire(budget) == %{
               "allocation" => 100,
               "strategy" => %{
                 "type" => "time_based",
                 "duration_ms" => 60_000,
                 "burst" => 5
               }
             }
    end

    test "an unset burst is omitted rather than sent as null" do
      budget =
        Budget.new!(key: "emails", allocation: 100, strategy: :time_based, duration: 60_000)

      refute Map.has_key?(Budget.to_wire(budget)["strategy"], "burst")
    end

    test "a concurrency limit carries the kind alone" do
      budget = Budget.new!(key: "stripe", allocation: 3, strategy: :while_in_flight)

      assert Budget.to_wire(budget) == %{
               "allocation" => 3,
               "strategy" => %{"type" => "while_in_flight"}
             }
    end

    # The key travels in the path and the timestamps are the server's,
    # so neither belongs in a request body.
    test "the body carries neither the key nor the timestamps" do
      budget = Budget.new!(key: "emails", allocation: 1, strategy: :while_in_flight)

      assert Map.keys(Budget.to_wire(budget)) == ["allocation", "strategy"]
    end

    test "reads back everything the server reports" do
      budget =
        Budget.from_wire(%{
          "key" => "emails",
          "allocation" => 100,
          "strategy" => %{"type" => "time_based", "duration_ms" => 90_000, "burst" => 5},
          "created_at" => 1_700_000_000_000,
          "updated_at" => 1_700_000_060_000
        })

      assert budget.key == "emails"
      assert budget.strategy == :time_based
      assert budget.duration == 90_000
      assert budget.burst == 5
      assert budget.created_at == DateTime.from_unix!(1_700_000_000_000, :millisecond)
    end

    # Round-tripping matters: a budget that has been read should be
    # writable again without being rewritten on the way through.
    test "survives a round trip" do
      budget =
        Budget.new!(
          key: "emails",
          allocation: 100,
          strategy: :time_based,
          duration: 90_000,
          burst: 5
        )

      read = Budget.from_wire(Map.put(Budget.to_wire(budget), "key", "emails"))

      assert read.allocation == budget.allocation
      assert read.strategy == budget.strategy
      assert read.duration == budget.duration
      assert read.burst == budget.burst
    end

    # A newer server may name a strategy this client does not know. It
    # reads through rather than raising, so the budget can still be
    # inspected and written back unchanged.
    test "an unrecognised kind passes through" do
      budget =
        Budget.from_wire(%{
          "key" => "future",
          "allocation" => 1,
          "strategy" => %{"type" => "sliding_window"}
        })

      assert budget.strategy == :sliding_window
    end
  end
end
