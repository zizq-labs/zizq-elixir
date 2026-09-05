# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Integration.BudgetTest do
  @moduledoc """
  Budgets against a real server.

  The unit tests pin what the client sends; only a round trip shows the
  server agreeing — particularly that `:duration` goes out as
  milliseconds and comes back as the same number, which a stubbed
  response cannot catch.

  Budget keys are global, so each test derives its own from a unique
  integer rather than sharing one, the way the other suites do with
  queue names.
  """

  use ExUnit.Case, async: false

  alias Zizq.Budget
  alias Zizq.BudgetChange

  # Budgets are Pro-gated; `test_helper.exs` excludes this tag when the
  # server has no licence.
  @moduletag :pro
  @moduletag capture_log: true

  setup do
    url = System.fetch_env!("ZIZQ_URL")
    start_supervised!({Zizq, name: :bg, url: url})

    n = System.unique_integer([:positive])
    %{url: url, key: "bg_#{n}", queue: "bg_#{n}", n: n}
  end

  defp enqueue!(ctx, opts) do
    opts
    |> Keyword.merge(type: "budget_probe", queue: ctx.queue)
    |> Keyword.put_new(:retention, completed: :timer.minutes(5))
    |> Zizq.enqueue!(:bg)
  end

  defp start_worker!(ctx, handler, opts \\ []) do
    opts =
      Keyword.merge(
        [
          client: :bg,
          handler: handler,
          queues: [ctx.queue],
          name: :"bgw_#{System.unique_integer([:positive])}",
          drain_timeout: 2_000
        ],
        opts
      )

    start_supervised!({Zizq.Worker, opts})
  end

  describe "policies" do
    test "define, read, amend and delete", ctx do
      assert {:ok, %Budget{}} =
               Zizq.define_budget(
                 [
                   key: ctx.key,
                   allocation: 100,
                   strategy: :time_based,
                   duration: :timer.minutes(1)
                 ],
                 :bg
               )

      # The round trip that matters: milliseconds out, the same
      # milliseconds back.
      assert {:ok, budget} = Zizq.get_budget(ctx.key, :bg)
      assert budget.allocation == 100
      assert budget.strategy == :time_based
      assert budget.duration == 60_000
      assert budget.burst == nil
      assert Budget.capacity(budget) == 100
      assert %DateTime{} = budget.created_at

      assert ctx.key in Enum.map(Zizq.list_budgets!(:bg), & &1.key)

      # Merge patch recurses into the strategy: the burst changes
      # without restating the kind or the period.
      assert {:ok, patched} = Zizq.update_budget(ctx.key, :bg, burst: 5)
      assert patched.burst == 5
      assert patched.duration == 60_000
      assert Budget.capacity(patched) == 5

      # `nil` is the one meaningful clear.
      assert {:ok, cleared} = Zizq.update_budget(ctx.key, :bg, burst: nil)
      assert cleared.burst == nil

      assert :ok = Zizq.delete_budget(ctx.key, :bg)
      assert {:error, %Zizq.Error{reason: :not_found}} = Zizq.get_budget(ctx.key, :bg)
    end

    test "a clockless budget round trips", ctx do
      assert {:ok, _} =
               Zizq.define_budget([key: ctx.key, allocation: 3, strategy: :while_in_flight], :bg)

      assert {:ok, budget} = Zizq.get_budget(ctx.key, :bg)
      assert Budget.while_in_flight?(budget)
      assert budget.duration == nil
      assert Budget.capacity(budget) == 3

      Zizq.delete_budget!(ctx.key, :bg)
    end

    # `POST` refuses rather than overwriting, which is what lets every
    # node declare its budgets on boot without coordinating.
    test "a second definition conflicts, and :replace does not", ctx do
      policy = [key: ctx.key, allocation: 1, strategy: :while_in_flight]

      assert {:ok, _} = Zizq.define_budget(policy, :bg)
      assert {:error, %Zizq.Error{reason: :conflict}} = Zizq.define_budget(policy, :bg)
      assert Zizq.get_budget!(ctx.key, :bg).allocation == 1

      assert {:ok, _} =
               Zizq.define_budget(Keyword.put(policy, :allocation, 5), :bg, replace: true)

      assert Zizq.get_budget!(ctx.key, :bg).allocation == 5

      Zizq.delete_budget!(ctx.key, :bg)
    end
  end

  describe "bindings" do
    test "bind at enqueue and read back off the job", ctx do
      Zizq.define_budget!([key: ctx.key, allocation: 100, strategy: :while_in_flight], :bg)

      job = enqueue!(ctx, payload: %{}, budgets: [[key: ctx.key, cost: 3]])

      assert [%Zizq.BudgetBinding{key: key, cost: 3}] = job.budgets
      assert key == ctx.key

      # And on a fresh read, not only on the enqueue response.
      assert [%Zizq.BudgetBinding{cost: 3}] = Zizq.get_job!(job, :bg).budgets

      Zizq.delete_all_jobs!([queue: ctx.queue], :bg)
      Zizq.delete_budget!(ctx.key, :bg)
    end

    # Binding and creating in one request, which is what lets an
    # application bring its own throttles up without a provisioning
    # step.
    test "create_with defines the budget as a side effect", ctx do
      job =
        enqueue!(ctx,
          payload: %{},
          budgets: [
            [
              key: ctx.key,
              cost: 2,
              create_with: [allocation: 50, strategy: :time_based, duration: :timer.seconds(30)]
            ]
          ]
        )

      assert [%Zizq.BudgetBinding{cost: 2}] = job.budgets

      assert {:ok, budget} = Zizq.get_budget(ctx.key, :bg)
      assert budget.allocation == 50
      assert budget.duration == 30_000

      Zizq.delete_all_jobs!([queue: ctx.queue], :bg)
      Zizq.delete_budget!(ctx.key, :bg)
    end

    test "the six single-job operations", ctx do
      other = ctx.key <> "_b"
      Zizq.define_budget!([key: ctx.key, allocation: 100, strategy: :while_in_flight], :bg)
      Zizq.define_budget!([key: other, allocation: 100, strategy: :while_in_flight], :bg)

      job = enqueue!(ctx, payload: %{})
      assert job.budgets == []

      assert {:ok, job} = Zizq.bind_budget(job, :bg, key: ctx.key, cost: 2)
      assert [%{cost: 2}] = job.budgets

      assert {:error, %Zizq.Error{reason: :conflict}} =
               Zizq.bind_budget(job, :bg, key: ctx.key)

      assert {:ok, job} = Zizq.set_budget_cost(job, :bg, ctx.key, 4)
      assert [%{cost: 4}] = job.budgets

      # A replace is whole, so the cost returns to the default.
      assert {:ok, job} = Zizq.rebind_budget(job, :bg, key: ctx.key)
      assert [%{cost: 1}] = job.budgets

      assert {:ok, job} =
               Zizq.replace_budgets(job, :bg, [[key: ctx.key], [key: other, cost: 5]])

      assert Enum.map(job.budgets, & &1.key) |> Enum.sort() == Enum.sort([ctx.key, other])

      assert {:ok, job} = Zizq.unbind_budget(job, :bg, other)
      assert [only] = job.budgets
      assert only.key == ctx.key

      assert {:ok, job} = Zizq.unbind_all_budgets(job, :bg)
      assert job.budgets == []

      Zizq.delete_all_jobs!([queue: ctx.queue], :bg)
      Zizq.delete_budget!(ctx.key, :bg)
      Zizq.delete_budget!(other, :bg)
    end

    # The pairing `:budgets_key` exists for: a budget cannot be deleted
    # while anything draws on it, and the filter selects exactly what
    # is in the way.
    test "drain a budget by what draws on it, then delete it", ctx do
      Zizq.define_budget!([key: ctx.key, allocation: 100, strategy: :while_in_flight], :bg)

      for _ <- 1..3, do: enqueue!(ctx, payload: %{}, budgets: [[key: ctx.key]])

      assert Zizq.count_jobs!([budgets_key: ctx.key], :bg) == 3
      assert {:error, %Zizq.Error{reason: :conflict}} = Zizq.delete_budget(ctx.key, :bg)

      change =
        Zizq.query(:bg)
        |> Zizq.Query.where(budgets_key: ctx.key)
        |> Zizq.Query.unbind_budget(ctx.key)

      assert %BudgetChange{changed: 3, blocked: []} = change
      assert BudgetChange.complete?(change)

      assert Zizq.count_jobs!([budgets_key: ctx.key], :bg) == 0
      assert :ok = Zizq.delete_budget(ctx.key, :bg)

      Zizq.delete_all_jobs!([queue: ctx.queue], :bg)
    end

    test "bulk bind and clear over a query", ctx do
      Zizq.define_budget!([key: ctx.key, allocation: 100, strategy: :while_in_flight], :bg)
      for _ <- 1..3, do: enqueue!(ctx, payload: %{})

      assert %BudgetChange{changed: 3} =
               Zizq.query(:bg)
               |> Zizq.Query.where(queue: ctx.queue)
               |> Zizq.Query.bind_budget(key: ctx.key, cost: 2)

      assert %BudgetChange{changed: 3} =
               Zizq.query(:bg)
               |> Zizq.Query.where(queue: ctx.queue)
               |> Zizq.Query.set_budget_cost(ctx.key, 7)

      costs =
        Zizq.list_jobs!([queue: ctx.queue], :bg).jobs
        |> Enum.map(fn job -> hd(job.budgets).cost end)

      assert costs == [7, 7, 7]

      assert %BudgetChange{changed: 3} =
               Zizq.query(:bg)
               |> Zizq.Query.where(queue: ctx.queue)
               |> Zizq.Query.unbind_all_budgets()

      assert Zizq.count_jobs!([budgets_key: ctx.key], :bg) == 0

      Zizq.delete_all_jobs!([queue: ctx.queue], :bg)
      Zizq.delete_budget!(ctx.key, :bg)
    end
  end

  describe "throttling" do
    # Asserted on overlap rather than on elapsed time, so a loaded
    # machine cannot make it flake: an allocation of 1 means the server
    # must never have two of these in flight together, however slowly
    # they run.
    @tag timeout: 60_000
    test "while_in_flight never runs two at once", ctx do
      Zizq.define_budget!([key: ctx.key, allocation: 1, strategy: :while_in_flight], :bg)

      for _ <- 1..5, do: enqueue!(ctx, payload: %{}, budgets: [[key: ctx.key]])

      {:ok, tracker} = Agent.start_link(fn -> %{in_flight: 0, peak: 0, done: 0} end)
      test_pid = self()

      start_worker!(
        ctx,
        fn _job ->
          Agent.update(tracker, fn s ->
            in_flight = s.in_flight + 1
            %{s | in_flight: in_flight, peak: max(s.peak, in_flight)}
          end)

          Process.sleep(50)

          Agent.update(tracker, fn s ->
            %{s | in_flight: s.in_flight - 1, done: s.done + 1}
          end)

          send(test_pid, :ran)
          :ok
        end,
        concurrency: 4
      )

      for _ <- 1..5, do: assert_receive(:ran, 30_000)

      state = Agent.get(tracker, & &1)
      assert state.done == 5
      assert state.peak == 1, "budget allowed #{state.peak} jobs in flight at once"

      Zizq.delete_all_jobs!([queue: ctx.queue], :bg)
      Zizq.delete_budget!(ctx.key, :bg)
    end

    # One token per *minute* with a burst of 1, so exactly one job is
    # affordable and the refill provably cannot arrive inside the
    # window this test waits. The assertion is a count, and the grace
    # is the best part of a minute.
    @tag timeout: 60_000
    test "a rate limit withholds what it cannot afford", ctx do
      Zizq.define_budget!(
        [
          key: ctx.key,
          allocation: 1,
          strategy: :time_based,
          duration: :timer.minutes(1),
          burst: 1
        ],
        :bg
      )

      for _ <- 1..3, do: enqueue!(ctx, payload: %{}, budgets: [[key: ctx.key]])

      test_pid = self()

      start_worker!(ctx, fn _job ->
        send(test_pid, :ran)
        :ok
      end)

      assert_receive :ran, 15_000
      refute_receive :ran, 5_000

      assert Zizq.count_jobs!([queue: ctx.queue, status: [:ready, :scheduled]], :bg) == 2

      Zizq.delete_all_jobs!([queue: ctx.queue], :bg)
      Zizq.delete_budget!(ctx.key, :bg)
    end

    # The positive control: a budget with room to spare must not hold
    # anything back, so a bug that throttles everything cannot pass the
    # test above by accident.
    @tag timeout: 60_000
    test "a generous budget does not throttle", ctx do
      Zizq.define_budget!(
        [key: ctx.key, allocation: 100, strategy: :time_based, duration: :timer.seconds(1)],
        :bg
      )

      for _ <- 1..3, do: enqueue!(ctx, payload: %{}, budgets: [[key: ctx.key]])

      test_pid = self()

      start_worker!(ctx, fn _job ->
        send(test_pid, :ran)
        :ok
      end)

      for _ <- 1..3, do: assert_receive(:ran, 20_000)

      Zizq.delete_all_jobs!([queue: ctx.queue], :bg)
      Zizq.delete_budget!(ctx.key, :bg)
    end
  end
end
