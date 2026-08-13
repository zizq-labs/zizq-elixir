# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Integration.BulkTest do
  @moduledoc """
  Changing and deleting many jobs against a real server.

  What matters here is the selection: a bulk operation that filters
  slightly too widely does the wrong thing to jobs nobody asked about,
  and looks identical to a correct one from the client's side. Each
  test enqueues jobs it wants left alone as well as jobs it wants
  changed, and asserts on both.
  """

  use ExUnit.Case, async: false

  setup do
    url = System.fetch_env!("ZIZQ_URL")
    start_supervised!({Zizq, name: :bulk, url: url})

    %{url: url, queue: "bulk_#{System.unique_integer([:positive])}"}
  end

  defp enqueue!(ctx, opts \\ []) do
    opts
    |> Keyword.put_new(:queue, ctx.queue)
    |> Keyword.put_new(:type, "bulk")
    |> Keyword.put_new(:retention, completed: :timer.minutes(5), dead: :timer.minutes(5))
    |> Zizq.enqueue!(:bulk)
  end

  describe "update_all_jobs/3" do
    test "changes every match and reports the count", ctx do
      for _ <- 1..3, do: enqueue!(ctx, priority: 100)

      assert {:ok, 3} =
               Zizq.update_all_jobs([where: [queue: ctx.queue], apply: [priority: 5]], :bulk)

      page = Zizq.list_jobs!([queue: ctx.queue], :bulk)
      assert Enum.all?(page.jobs, &(&1.priority == 5))
    end

    # The property worth paying for: a job outside the filter must come
    # through untouched.
    test "leaves jobs outside the filter alone", ctx do
      wanted = enqueue!(ctx, type: "wanted", priority: 100)
      other = enqueue!(ctx, type: "other", priority: 100)

      assert {:ok, 1} =
               Zizq.update_all_jobs(
                 [where: [queue: ctx.queue, type: "wanted"], apply: [priority: 5]],
                 :bulk
               )

      assert Zizq.get_job!(wanted.id, :bulk).priority == 5
      assert Zizq.get_job!(other.id, :bulk).priority == 100
    end

    test "narrows by a range as a listing would", ctx do
      low = enqueue!(ctx, priority: 10)
      high = enqueue!(ctx, priority: 90)

      assert {:ok, 1} =
               Zizq.update_all_jobs(
                 [where: [queue: ctx.queue, priority: [max: 50]], apply: [priority: 0]],
                 :bulk
               )

      assert Zizq.get_job!(low.id, :bulk).priority == 0
      assert Zizq.get_job!(high.id, :bulk).priority == 90
    end

    test "merge-patch rules hold in bulk too", ctx do
      job = enqueue!(ctx, priority: 100, retry_limit: 9)

      assert {:ok, 1} =
               Zizq.update_all_jobs([where: [queue: ctx.queue], apply: [priority: 5]], :bulk)

      updated = Zizq.get_job!(job.id, :bulk)
      assert updated.priority == 5
      assert updated.retry_limit == 9
    end

    test "matching nothing changes nothing", ctx do
      enqueue!(ctx)

      assert {:ok, 0} =
               Zizq.update_all_jobs(
                 [where: [queue: "#{ctx.queue}_absent"], apply: [priority: 1]],
                 :bulk
               )
    end

    # Rejected locally, so this never reaches the server — the server
    # would answer 422 for the same reason.
    test "a terminal status filter is refused", ctx do
      assert_raise ArgumentError, ~r/not editable/, fn ->
        Zizq.update_all_jobs(
          [where: [queue: ctx.queue, status: :completed], apply: [priority: 1]],
          :bulk
        )
      end
    end
  end

  describe "delete_all_jobs/2" do
    test "deletes every match and reports the count", ctx do
      jobs = for _ <- 1..3, do: enqueue!(ctx)

      assert {:ok, 3} = Zizq.delete_all_jobs([queue: ctx.queue], :bulk)

      for job <- jobs do
        assert {:error, %Zizq.Error{reason: :not_found}} = Zizq.get_job(job.id, :bulk)
      end
    end

    test "leaves jobs outside the filter alone", ctx do
      doomed = enqueue!(ctx, type: "doomed")
      spared = enqueue!(ctx, type: "spared")

      assert {:ok, 1} = Zizq.delete_all_jobs([queue: ctx.queue, type: "doomed"], :bulk)

      assert {:error, %Zizq.Error{reason: :not_found}} = Zizq.get_job(doomed.id, :bulk)
      assert Zizq.get_job!(spared.id, :bulk).id == spared.id
    end

    # Counting with the same filters is the way to see what would go,
    # so the two had better agree.
    test "deletes exactly what the same filters counted", ctx do
      for _ <- 1..4, do: enqueue!(ctx, type: "target")
      for _ <- 1..2, do: enqueue!(ctx, type: "bystander")

      filters = [queue: ctx.queue, type: "target"]

      assert {:ok, 4} = Zizq.count_jobs(filters, :bulk)
      assert {:ok, 4} = Zizq.delete_all_jobs(filters, :bulk)
      assert {:ok, 2} = Zizq.count_jobs([queue: ctx.queue], :bulk)
    end

    test "matching nothing deletes nothing", ctx do
      enqueue!(ctx)

      assert {:ok, 0} = Zizq.delete_all_jobs([queue: "#{ctx.queue}_absent"], :bulk)
      assert {:ok, 1} = Zizq.count_jobs([queue: ctx.queue], :bulk)
    end

    test "a jq filter narrows on the payload", ctx do
      wanted = enqueue!(ctx, payload: %{"tenant" => 1})
      other = enqueue!(ctx, payload: %{"tenant" => 2})

      assert {:ok, 1} =
               Zizq.delete_all_jobs([queue: ctx.queue, filter: ".tenant == 1"], :bulk)

      assert {:error, %Zizq.Error{reason: :not_found}} = Zizq.get_job(wanted.id, :bulk)
      assert Zizq.get_job!(other.id, :bulk).id == other.id
    end
  end
end
