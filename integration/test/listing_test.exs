# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Integration.ListingTest do
  @moduledoc """
  Listing, counting and paging against a real server.

  The unit tests pin what the query string looks like; only the server
  says whether it read it. Comma-delimited sets and `A..B` ranges are
  interpreted there, so a filter that encodes plausibly but selects the
  wrong jobs looks identical to a correct one until now.
  """

  use ExUnit.Case, async: false

  setup do
    url = System.fetch_env!("ZIZQ_URL")
    start_supervised!({Zizq, name: :list, url: url})

    %{url: url, queue: "list_#{System.unique_integer([:positive])}"}
  end

  defp enqueue!(ctx, opts) do
    opts
    |> Keyword.merge(queue: Keyword.get(opts, :queue, ctx.queue))
    |> Keyword.put_new(:type, "listing")
    |> Keyword.put_new(:retention, completed: :timer.minutes(5))
    |> Zizq.enqueue!(:list)
  end

  defp ids(page_or_jobs)
  defp ids(%Zizq.JobPage{jobs: jobs}), do: Enum.map(jobs, & &1.id)
  defp ids(jobs) when is_list(jobs), do: Enum.map(jobs, & &1.id)

  describe "list_jobs/2" do
    test "finds the jobs on a queue", ctx do
      a = enqueue!(ctx, [])
      b = enqueue!(ctx, [])
      _elsewhere = enqueue!(ctx, queue: "#{ctx.queue}_other")

      page = Zizq.list_jobs!([queue: ctx.queue], :list)

      assert Enum.sort(ids(page)) == Enum.sort([a.id, b.id])
    end

    test "a list matches any of its members", ctx do
      a = enqueue!(ctx, type: "alpha")
      b = enqueue!(ctx, type: "beta")
      _c = enqueue!(ctx, type: "gamma")

      page = Zizq.list_jobs!([queue: ctx.queue, type: ["alpha", "beta"]], :list)

      assert Enum.sort(ids(page)) == Enum.sort([a.id, b.id])
    end

    # The encoding says `1..10`; only the server decides that means an
    # inclusive span.
    test "a range selects inclusively at both ends", ctx do
      low = enqueue!(ctx, priority: 10)
      mid = enqueue!(ctx, priority: 20)
      high = enqueue!(ctx, priority: 30)

      page = Zizq.list_jobs!([queue: ctx.queue, priority: 10..20], :list)
      selected = ids(page)

      assert low.id in selected
      assert mid.id in selected
      refute high.id in selected
    end

    test "a one-sided bound selects from there on", ctx do
      low = enqueue!(ctx, priority: 10)
      high = enqueue!(ctx, priority: 30)

      selected = ids(Zizq.list_jobs!([queue: ctx.queue, priority: [min: 20]], :list))

      assert high.id in selected
      refute low.id in selected
    end

    test "status narrows to a lifecycle state", ctx do
      ready = enqueue!(ctx, [])
      scheduled = enqueue!(ctx, ready_at: DateTime.add(DateTime.utc_now(), 3_600, :second))

      selected = ids(Zizq.list_jobs!([queue: ctx.queue, status: :scheduled], :list))

      assert scheduled.id in selected
      refute ready.id in selected
    end

    test "a jq filter runs against the payload", ctx do
      wanted = enqueue!(ctx, payload: %{"user_id" => 42})
      _other = enqueue!(ctx, payload: %{"user_id" => 7})

      selected = ids(Zizq.list_jobs!([queue: ctx.queue, filter: ".user_id == 42"], :list))

      assert selected == [wanted.id]
    end

    test "order and limit shape the page", ctx do
      for n <- 1..5, do: enqueue!(ctx, priority: n)

      asc = Zizq.list_jobs!([queue: ctx.queue, order: :asc, limit: 2], :list)
      desc = Zizq.list_jobs!([queue: ctx.queue, order: :desc, limit: 2], :list)

      assert length(asc.jobs) == 2
      assert length(desc.jobs) == 2
      refute ids(asc) == ids(desc)
    end
  end

  describe "paging" do
    test "walks every job exactly once", ctx do
      enqueued = for _ <- 1..7, do: enqueue!(ctx, [])

      walked = walk(Zizq.list_jobs!([queue: ctx.queue, limit: 2], :list), [])

      assert Enum.sort(walked) == Enum.sort(Enum.map(enqueued, & &1.id))
      assert length(walked) == length(Enum.uniq(walked))
    end

    test "the last page ends the walk", ctx do
      enqueue!(ctx, [])

      page = Zizq.list_jobs!([queue: ctx.queue, limit: 50], :list)

      assert Zizq.next_page(page, :list) == {:ok, nil}
    end

    # The link carries the filters, so following it cannot widen the
    # query — the failure mode if a client rebuilt the URL itself.
    test "a followed link keeps the original filters", ctx do
      for _ <- 1..3, do: enqueue!(ctx, type: "wanted")
      for _ <- 1..3, do: enqueue!(ctx, type: "unwanted")

      first = Zizq.list_jobs!([queue: ctx.queue, type: "wanted", limit: 2], :list)
      {:ok, second} = Zizq.next_page(first, :list)

      assert Enum.all?(first.jobs ++ second.jobs, &(&1.type == "wanted"))
    end

    # Which jobs come back is the contract; what order they come back
    # in is not. At the time of writing the server returns them
    # reversed, because `prev` carries the opposite `order` to the
    # request that produced it.
    test "prev_page walks back to the jobs the previous page held", ctx do
      for _ <- 1..4, do: enqueue!(ctx, [])

      first = Zizq.list_jobs!([queue: ctx.queue, limit: 2], :list)
      {:ok, second} = Zizq.next_page(first, :list)
      {:ok, back} = Zizq.prev_page(second, :list)

      assert Enum.sort(ids(back)) == Enum.sort(ids(first))
    end

    test "the server lists oldest first unless told otherwise", ctx do
      first = enqueue!(ctx, [])
      second = enqueue!(ctx, [])

      assert ids(Zizq.list_jobs!([queue: ctx.queue], :list)) == [first.id, second.id]
    end
  end

  describe "count_jobs/2" do
    test "counts what a listing would return", ctx do
      for _ <- 1..5, do: enqueue!(ctx, [])
      _elsewhere = enqueue!(ctx, queue: "#{ctx.queue}_other")

      assert Zizq.count_jobs!([queue: ctx.queue], :list) == 5
    end

    test "counts past the page size", ctx do
      for _ <- 1..5, do: enqueue!(ctx, [])

      page = Zizq.list_jobs!([queue: ctx.queue, limit: 2], :list)

      assert length(page.jobs) == 2
      assert Zizq.count_jobs!([queue: ctx.queue], :list) == 5
    end

    test "counts nothing when nothing matches", ctx do
      assert Zizq.count_jobs!([queue: "#{ctx.queue}_empty"], :list) == 0
    end
  end

  describe "list_queues/1" do
    test "reports a queue once a job has named it", ctx do
      refute ctx.queue in Zizq.list_queues!(:list)

      enqueue!(ctx, [])

      assert ctx.queue in Zizq.list_queues!(:list)
    end
  end

  defp walk(page, acc) do
    acc = acc ++ ids(page)

    case Zizq.next_page(page, :list) do
      {:ok, nil} -> acc
      {:ok, next} -> walk(next, acc)
    end
  end
end
