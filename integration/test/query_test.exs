# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Integration.QueryTest do
  @moduledoc """
  The query builder against a real server.

  The unit tests pin how much it fetches; this pins that what it
  fetches is right — that paging under a real cursor yields every job
  once, and that filters narrow the same way whether a query or a
  one-shot call carries them.
  """

  use ExUnit.Case, async: false

  alias Zizq.Query

  setup do
    url = System.fetch_env!("ZIZQ_URL")
    start_supervised!({Zizq, name: :q, url: url})

    %{url: url, queue: "q_#{System.unique_integer([:positive])}"}
  end

  defp enqueue!(ctx, opts) do
    opts
    |> Keyword.put_new(:queue, ctx.queue)
    |> Keyword.put_new(:type, "query")
    |> Keyword.put_new(:retention, completed: :timer.minutes(5))
    |> Zizq.enqueue!(:q)
  end

  defp query(ctx), do: Zizq.query(:q) |> Query.where(queue: ctx.queue)

  test "walks every matching job exactly once", ctx do
    enqueued = for n <- 1..7, do: enqueue!(ctx, payload: %{"n" => n})

    ids = ctx |> query() |> Query.in_pages_of(2) |> Enum.map(& &1.id)

    assert Enum.sort(ids) == Enum.sort(Enum.map(enqueued, & &1.id))
    assert length(ids) == length(Enum.uniq(ids))
  end

  test "the page size does not change what comes back", ctx do
    for n <- 1..6, do: enqueue!(ctx, payload: %{"n" => n})

    one_page = ctx |> query() |> Query.in_pages_of(100) |> Enum.map(& &1.id)
    many_pages = ctx |> query() |> Query.in_pages_of(2) |> Enum.map(& &1.id)

    assert one_page == many_pages
  end

  test "filters narrow as they do on a one-shot call", ctx do
    wanted = enqueue!(ctx, type: "wanted")
    _other = enqueue!(ctx, type: "other")

    from_query = ctx |> query() |> Query.where(type: "wanted") |> Enum.map(& &1.id)
    from_call = Zizq.list_jobs!([queue: ctx.queue, type: "wanted"], :q).jobs

    assert from_query == [wanted.id]
    assert from_query == Enum.map(from_call, & &1.id)
  end

  test "limit caps the result across pages", ctx do
    for n <- 1..10, do: enqueue!(ctx, payload: %{"n" => n})

    assert ctx |> query() |> Query.limit(4) |> Query.in_pages_of(3) |> Enum.count() == 4
  end

  test "order reverses the run", ctx do
    for n <- 1..4, do: enqueue!(ctx, payload: %{"n" => n})

    asc = ctx |> query() |> Query.order(:asc) |> Enum.map(& &1.id)
    desc = ctx |> query() |> Query.order(:desc) |> Enum.map(& &1.id)

    assert desc == Enum.reverse(asc)
  end

  # Counting asks the server, so it must agree with what enumerating
  # actually yields — the two take different routes to the same answer.
  test "counting agrees with enumerating", ctx do
    for n <- 1..9, do: enqueue!(ctx, payload: %{"n" => n})

    assert Enum.count(query(ctx)) == 9
    assert query(ctx) |> Query.count() == 9
    assert query(ctx) |> Query.in_pages_of(2) |> Enum.to_list() |> length() == 9
  end

  test "a jq filter reaches the server", ctx do
    wanted = enqueue!(ctx, payload: %{"tenant" => 1})
    _other = enqueue!(ctx, payload: %{"tenant" => 2})

    ids = ctx |> query() |> Query.where(filter: ".tenant == 1") |> Enum.map(& &1.id)

    assert ids == [wanted.id]
  end

  test "pages/1 yields whole pages", ctx do
    for n <- 1..5, do: enqueue!(ctx, payload: %{"n" => n})

    pages = ctx |> query() |> Query.in_pages_of(2) |> Query.pages() |> Enum.to_list()

    assert Enum.map(pages, &length(&1.jobs)) == [2, 2, 1]
    assert Enum.all?(pages, &match?(%Zizq.JobPage{}, &1))
  end

  test "matching nothing yields nothing", ctx do
    assert Zizq.query(:q) |> Query.where(queue: "#{ctx.queue}_absent") |> Enum.to_list() == []
    assert Zizq.query(:q) |> Query.where(queue: "#{ctx.queue}_absent") |> Enum.count() == 0
  end

  describe "acting on everything matched" do
    test "update_all changes exactly what the query counted", ctx do
      for _ <- 1..4, do: enqueue!(ctx, type: "target", priority: 100)
      for _ <- 1..2, do: enqueue!(ctx, type: "bystander", priority: 100)

      targets = ctx |> query() |> Query.where(type: "target")

      assert Query.count(targets) == 4
      assert Query.update_all(targets, priority: 5) == 4

      assert Enum.all?(Enum.to_list(targets), &(&1.priority == 5))

      assert ctx
             |> query()
             |> Query.where(type: "bystander")
             |> Enum.all?(&(&1.priority == 100))
    end

    # A page size turns one enormous request into a run of bounded
    # ones — the reason to want it at ten million jobs.
    test "in_pages_of works through the matches a page at a time", ctx do
      for _ <- 1..10, do: enqueue!(ctx, priority: 100)

      updated =
        ctx |> query() |> Query.in_pages_of(3) |> Query.update_all(priority: 5)

      assert updated == 10
      assert ctx |> query() |> Enum.all?(&(&1.priority == 5))
    end

    # Deleting removes the job the next page's cursor names, which is
    # fine: the cursor is a position in a range scan, not a reference
    # to a row that has to still be there.
    test "batched deletion walks past its own deletions", ctx do
      jobs = for _ <- 1..10, do: enqueue!(ctx, [])

      assert ctx |> query() |> Query.in_pages_of(3) |> Query.delete_all() == 10

      assert ctx |> query() |> Enum.count() == 0

      for job <- jobs do
        assert {:error, %Zizq.Error{reason: :not_found}} = Zizq.get_job(job.id, :q)
      end
    end

    test "batching still respects the filters", ctx do
      for _ <- 1..6, do: enqueue!(ctx, type: "doomed")
      for _ <- 1..3, do: enqueue!(ctx, type: "spared")

      deleted =
        ctx
        |> query()
        |> Query.where(type: "doomed")
        |> Query.in_pages_of(2)
        |> Query.delete_all()

      assert deleted == 6
      assert ctx |> query() |> Enum.count() == 3
    end

    test "a limit caps how many batching touches", ctx do
      for _ <- 1..10, do: enqueue!(ctx, priority: 100)

      updated =
        ctx |> query() |> Query.limit(4) |> Query.in_pages_of(3) |> Query.update_all(priority: 5)

      assert updated == 4
      assert ctx |> query() |> Query.where(priority: 5) |> Enum.count() == 4
      assert ctx |> query() |> Query.where(priority: 100) |> Enum.count() == 6
    end

    test "delete_all deletes exactly what the query counted", ctx do
      for _ <- 1..3, do: enqueue!(ctx, type: "doomed")
      for _ <- 1..2, do: enqueue!(ctx, type: "spared")

      doomed = ctx |> query() |> Query.where(type: "doomed")

      assert Query.count(doomed) == 3
      assert Query.delete_all(doomed) == 3

      assert Enum.to_list(doomed) == []
      assert ctx |> query() |> Enum.count() == 2
    end
  end
end
