# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.QueryTest do
  @moduledoc """
  The query builder, against a server that reports every request it
  receives — so the tests can assert on how much was fetched, not just
  on what came back. Fetching more pages than a caller asked for is
  the failure mode a lazy query exists to avoid.
  """

  use ExUnit.Case, async: true

  alias Zizq.FakeServer
  alias Zizq.Query

  # Serves a fixed run of jobs, `per_page` at a time, and reports each
  # request so a test can count them.
  defp paged_server(total, per_page) do
    test_pid = self()

    FakeServer.start_client!(
      fn conn ->
        send(test_pid, {:request, conn.request_path, conn.query_string})
        params = URI.decode_query(conn.query_string)
        from = params |> Map.get("from", "0") |> String.to_integer()
        limit = params |> Map.get("limit", "#{per_page}") |> String.to_integer()

        taken = Enum.to_list(from..(from + min(limit, per_page) - 1)//1)
        taken = Enum.filter(taken, &(&1 < total))
        next_from = from + length(taken)

        body =
          JSON.encode!(%{
            "jobs" => Enum.map(taken, &job/1),
            "pages" =>
              if next_from < total do
                %{"next" => "/jobs?from=#{next_from}&limit=#{limit}"}
              else
                %{}
              end
          })

        FakeServer.respond(conn, 200, "application/json", body)
      end,
      format: :json
    )
  end

  defp job(n) do
    %{
      "id" => "job-#{n}",
      "type" => "probe",
      "queue" => "default",
      "status" => "ready",
      "payload" => %{"n" => n},
      "attempts" => 0
    }
  end

  defp requests, do: collect_requests([])

  defp collect_requests(acc) do
    receive do
      {:request, _path, query} -> collect_requests([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "building" do
    test "builds without sending anything" do
      name = paged_server(10, 2)

      Zizq.query(name)
      |> Query.where(queue: "emails")
      |> Query.order(:desc)
      |> Query.limit(5)
      |> Query.in_pages_of(2)

      assert requests() == []
    end

    test "where/2 merges, with later calls winning" do
      name = paged_server(0, 2)

      Zizq.query(name)
      |> Query.where(queue: "emails", status: :ready)
      |> Query.where(status: :dead)
      |> Enum.to_list()

      assert [query] = requests()
      params = URI.decode_query(query)

      assert params["queue"] == "emails"
      assert params["status"] == "dead"
    end

    # Caught at the line that made the mistake, rather than wherever
    # the query happens to be run.
    test "an unknown filter is rejected when it is added" do
      name = paged_server(0, 2)

      assert_raise ArgumentError, ~r/unknown filter/, fn ->
        Zizq.query(name) |> Query.where(queeue: "emails")
      end
    end
  end

  describe "enumerating" do
    test "walks every page" do
      name = paged_server(5, 2)

      jobs = Zizq.query(name) |> Enum.to_list()

      assert length(jobs) == 5
      assert Enum.map(jobs, & &1.payload["n"]) == [0, 1, 2, 3, 4]
      assert %Zizq.Job{} = hd(jobs)
    end

    # The property laziness is for: `Enum.take/2` stops asking, so the
    # query stops fetching.
    test "take/2 stops fetching once it has enough" do
      name = paged_server(100, 2)

      jobs = Zizq.query(name) |> Enum.take(3)

      assert length(jobs) == 3
      # Two pages of two covers three jobs; a third would be waste.
      assert length(requests()) == 2
    end

    test "limit caps the total, and the request size with it" do
      name = paged_server(100, 50)

      jobs = Zizq.query(name) |> Query.limit(3) |> Enum.to_list()

      assert length(jobs) == 3
      assert [query] = requests()
      # Asking for 50 only to discard 47 would be the obvious mistake.
      assert URI.decode_query(query)["limit"] == "3"
    end

    test "in_pages_of sets the request size without capping the total" do
      name = paged_server(6, 100)

      jobs = Zizq.query(name) |> Query.in_pages_of(2) |> Enum.to_list()

      assert length(jobs) == 6
      assert length(requests()) == 3
    end

    test "the smaller of limit and page size decides one request" do
      name = paged_server(100, 100)

      Zizq.query(name) |> Query.limit(3) |> Query.in_pages_of(10) |> Enum.to_list()

      assert [query | _] = requests()
      assert URI.decode_query(query)["limit"] == "3"
    end

    test "order rides along" do
      name = paged_server(0, 2)

      Zizq.query(name) |> Query.order(:desc) |> Enum.to_list()

      assert [query] = requests()
      assert URI.decode_query(query)["order"] == "desc"
    end

    test "an empty result is an empty list" do
      name = paged_server(0, 2)

      assert Zizq.query(name) |> Enum.to_list() == []
    end

    test "works with Stream, staying lazy" do
      name = paged_server(100, 2)

      result =
        Zizq.query(name)
        |> Stream.map(& &1.payload["n"])
        |> Stream.filter(&(rem(&1, 2) == 0))
        |> Enum.take(2)

      assert result == [0, 2]
      assert length(requests()) <= 3
    end
  end

  describe "counting" do
    test "asks the server instead of walking pages" do
      test_pid = self()

      name =
        FakeServer.start_client!(
          fn conn ->
            send(test_pid, {:request, conn.request_path, conn.query_string})
            FakeServer.respond(conn, 200, "application/json", ~s({"count":1284}))
          end,
          format: :json
        )

      assert Zizq.query(name) |> Query.where(queue: "emails") |> Enum.count() == 1284

      assert [{"/jobs/count", query}] = collect_paths([])
      assert URI.decode_query(query)["queue"] == "emails"
    end

    # A count that ignored the limit would disagree with enumerating
    # the same query — two routes to what should be one number.
    test "a limit caps the count, as it caps everything else" do
      name =
        FakeServer.start_client!(
          fn conn -> FakeServer.respond(conn, 200, "application/json", ~s({"count":100})) end,
          format: :json
        )

      assert Zizq.query(name) |> Query.limit(4) |> Enum.count() == 4
      assert Zizq.query(name) |> Query.limit(4) |> Query.count() == 4
      assert Zizq.query(name) |> Query.limit(500) |> Query.count() == 100
    end

    test "count/1 does the same thing directly" do
      name =
        FakeServer.start_client!(
          fn conn -> FakeServer.respond(conn, 200, "application/json", ~s({"count":7})) end,
          format: :json
        )

      assert Zizq.query(name) |> Query.count() == 7
    end
  end

  defp collect_bulks(acc) do
    receive do
      {:bulk, query, body} -> collect_bulks([{query, body} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp collect_paths(acc) do
    receive do
      {:request, path, query} -> collect_paths([{path, query} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "acting on everything matched" do
    defp bulk_server(body) do
      test_pid = self()

      FakeServer.start_client!(
        fn conn ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          decoded = if raw == "", do: nil, else: JSON.decode!(raw)
          send(test_pid, {:bulk, conn.method, conn.query_string, decoded})
          FakeServer.respond(conn, 200, "application/json", body)
        end,
        format: :json
      )
    end

    test "update_all applies the changes to the filters" do
      name = bulk_server(~s({"patched":9}))

      count =
        Zizq.query(name)
        |> Query.where(queue: "emails", status: :scheduled)
        |> Query.update_all(ready_at: nil)

      assert count == 9
      assert_receive {:bulk, "PATCH", query, body}
      assert URI.decode_query(query)["queue"] == "emails"
      assert body == %{"ready_at" => nil}
    end

    test "delete_all deletes the filters" do
      name = bulk_server(~s({"deleted":4}))

      assert Zizq.query(name) |> Query.where(queue: "emails") |> Query.delete_all() == 4
      assert_receive {:bulk, "DELETE", query, _}
      assert URI.decode_query(query)["queue"] == "emails"
    end

    test "one request when nothing asks for batching" do
      name = bulk_server(~s({"patched":3}))

      assert Zizq.query(name) |> Query.where(queue: "emails") |> Query.update_all(priority: 1) ==
               3

      assert_receive {:bulk, "PATCH", _, _}
      refute_receive {:bulk, _, _, _}
    end
  end

  describe "working in batches" do
    # A page size turns one enormous request into a run of bounded
    # ones — the point being to act on ten million jobs without
    # holding everything at once.
    test "in_pages_of acts a page at a time, by id" do
      test_pid = self()

      name =
        FakeServer.start_client!(
          fn conn ->
            {:ok, raw, conn} = Plug.Conn.read_body(conn)

            case conn.method do
              "GET" ->
                send(test_pid, {:list, conn.query_string})
                params = URI.decode_query(conn.query_string)
                from = params |> Map.get("from", "0") |> String.to_integer()
                taken = Enum.filter(from..(from + 1)//1, &(&1 < 5))

                pages =
                  if from + length(taken) < 5,
                    do: %{"next" => "/jobs?from=#{from + length(taken)}&limit=2"},
                    else: %{}

                FakeServer.respond(
                  conn,
                  200,
                  "application/json",
                  JSON.encode!(%{"jobs" => Enum.map(taken, &job/1), "pages" => pages})
                )

              _ ->
                body = if raw == "", do: nil, else: JSON.decode!(raw)
                send(test_pid, {:bulk, conn.query_string, body})
                FakeServer.respond(conn, 200, "application/json", ~s({"patched":2}))
            end
          end,
          format: :json
        )

      total =
        Zizq.query(name)
        |> Query.where(queue: "emails")
        |> Query.in_pages_of(2)
        |> Query.update_all(priority: 1)

      # Three pages of the five jobs, so three bulk calls; the count is
      # the sum across them.
      assert total == 6

      bulks = collect_bulks([])
      assert length(bulks) == 3

      # Each carries that page's ids *and* the original filters, so a
      # job that stopped matching in between is left alone.
      for {query, _body} <- bulks do
        params = URI.decode_query(query)
        assert params["queue"] == "emails"
        assert params["id"] =~ "job-"
      end
    end

    test "a limit batches too, and stops once it is reached" do
      test_pid = self()

      name =
        FakeServer.start_client!(
          fn conn ->
            {:ok, raw, conn} = Plug.Conn.read_body(conn)

            case conn.method do
              "GET" ->
                params = URI.decode_query(conn.query_string)
                from = params |> Map.get("from", "0") |> String.to_integer()

                FakeServer.respond(
                  conn,
                  200,
                  "application/json",
                  JSON.encode!(%{
                    "jobs" => Enum.map(from..(from + 1)//1, &job/1),
                    "pages" => %{"next" => "/jobs?from=#{from + 2}&limit=2"}
                  })
                )

              _ ->
                body = if raw == "", do: nil, else: JSON.decode!(raw)
                send(test_pid, {:bulk, conn.query_string, body})
                FakeServer.respond(conn, 200, "application/json", ~s({"deleted":2}))
            end
          end,
          format: :json
        )

      Zizq.query(name) |> Query.limit(3) |> Query.in_pages_of(2) |> Query.delete_all()

      bulks = collect_bulks([])
      ids = Enum.flat_map(bulks, &(URI.decode_query(elem(&1, 0))["id"] |> String.split(",")))

      # Three, not four: the second page is trimmed rather than the
      # limit being overshot against an endless listing.
      assert length(ids) == 3
    end
  end

  describe "pages/1" do
    test "streams pages rather than jobs" do
      name = paged_server(5, 2)

      pages = Zizq.query(name) |> Query.pages() |> Enum.to_list()

      assert length(pages) == 3
      assert Enum.map(pages, &length(&1.jobs)) == [2, 2, 1]
      assert %Zizq.JobPage{} = hd(pages)
    end

    test "stays lazy" do
      name = paged_server(100, 2)

      pages = Zizq.query(name) |> Query.pages() |> Enum.take(2)

      assert length(pages) == 2
      assert length(requests()) == 2
    end
  end
end
