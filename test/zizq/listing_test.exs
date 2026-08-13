# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.ListingTest do
  @moduledoc """
  Listing, counting and paging, against a server that reports back the
  path it was asked for — so a test can assert on the query string as
  well as on what came back.
  """

  use ExUnit.Case, async: true

  alias Zizq.FakeServer

  defp server(status, body) do
    test_pid = self()

    FakeServer.start_client!(
      fn conn ->
        send(test_pid, {:request, conn.method, conn.request_path, conn.query_string})
        FakeServer.respond(conn, status, "application/json", body)
      end,
      format: :json
    )
  end

  defp job(id, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "type" => "probe",
        "queue" => "default",
        "status" => "ready",
        "payload" => %{},
        "attempts" => 0
      },
      overrides
    )
  end

  defp page(jobs, pages \\ %{}) do
    JSON.encode!(%{"jobs" => jobs, "pages" => pages})
  end

  describe "list_jobs/2" do
    test "returns a page of jobs" do
      name = server(200, page([job("a"), job("b")]))

      assert {:ok, %Zizq.JobPage{jobs: [%Zizq.Job{id: "a"}, %Zizq.Job{id: "b"}]}} =
               Zizq.list_jobs(name)

      assert_receive {:request, "GET", "/jobs", _}
    end

    test "filters become query parameters" do
      name = server(200, page([]))

      Zizq.list_jobs([queue: "emails", status: [:ready, :scheduled], priority: 1..10], name)

      assert_receive {:request, "GET", "/jobs", query}
      params = URI.decode_query(query)

      assert params["queue"] == "emails"
      assert params["status"] == "ready,scheduled"
      assert params["priority"] == "1..10"
    end

    test "limit and order are sent alongside the filters" do
      name = server(200, page([]))

      Zizq.list_jobs([queue: "emails", limit: 100, order: :asc], name)

      assert_receive {:request, "GET", "/jobs", query}
      params = URI.decode_query(query)

      assert params["limit"] == "100"
      assert params["order"] == "asc"
      assert params["queue"] == "emails"
    end

    test "nothing is sent when nothing was asked for" do
      name = server(200, page([]))

      Zizq.list_jobs(name)

      assert_receive {:request, "GET", "/jobs", ""}
    end

    test "rejects a nonsensical limit or order" do
      name = server(200, page([]))

      assert_raise ArgumentError, ~r/:limit must be a positive integer/, fn ->
        Zizq.list_jobs([limit: 0], name)
      end

      assert_raise ArgumentError, ~r/:order must be :asc or :desc/, fn ->
        Zizq.list_jobs([order: :sideways], name)
      end
    end

    test "an unknown filter is rejected before any request is made" do
      name = server(200, page([]))

      assert_raise ArgumentError, ~r/unknown filter/, fn ->
        Zizq.list_jobs([queeue: "emails"], name)
      end

      refute_receive {:request, _, _, _}
    end

    test "the bang variant raises" do
      name = server(500, ~s({"error":"boom"}))

      assert_raise Zizq.Error, fn -> Zizq.list_jobs!(name) end
    end
  end

  describe "paging" do
    test "carries the links the server supplied" do
      name = server(200, page([job("a")], %{"self" => "/jobs?x=1", "next" => "/jobs?from=a"}))

      assert {:ok, page} = Zizq.list_jobs(name)

      assert page.self == "/jobs?x=1"
      assert page.next == "/jobs?from=a"
      assert page.prev == nil
      assert Zizq.JobPage.has_next?(page)
      refute Zizq.JobPage.has_prev?(page)
    end

    test "has_prev? reports a page behind this one" do
      name = server(200, page([job("a")], %{"prev" => "/jobs?before=a"}))

      assert {:ok, page} = Zizq.list_jobs(name)

      assert Zizq.JobPage.has_prev?(page)
      refute Zizq.JobPage.has_next?(page)
    end

    # Followed verbatim rather than rebuilt, so the cursor and the
    # original filters cannot drift apart.
    test "next_page follows the server's link exactly" do
      name = server(200, page([job("a")], %{"next" => "/jobs?from=a&queue=emails"}))

      {:ok, page} = Zizq.list_jobs([queue: "emails"], name)
      assert_receive {:request, "GET", "/jobs", _}

      Zizq.next_page(page, name)

      assert_receive {:request, "GET", "/jobs", "from=a&queue=emails"}
    end

    test "the last page has no next" do
      name = server(200, page([job("a")], %{"self" => "/jobs"}))

      {:ok, page} = Zizq.list_jobs(name)

      refute Zizq.JobPage.has_next?(page)
      assert Zizq.next_page(page, name) == {:ok, nil}
    end

    test "prev_page works the same way" do
      name = server(200, page([job("a")], %{"prev" => "/jobs?before=a"}))

      {:ok, page} = Zizq.list_jobs(name)
      assert_receive {:request, _, _, _}

      Zizq.prev_page(page, name)
      assert_receive {:request, "GET", "/jobs", "before=a"}
    end

    test "the first page has no prev" do
      name = server(200, page([job("a")]))

      {:ok, page} = Zizq.list_jobs(name)

      assert Zizq.prev_page(page, name) == {:ok, nil}
    end

    test "a response without a pages object still works" do
      name = server(200, JSON.encode!(%{"jobs" => [job("a")]}))

      assert {:ok, %Zizq.JobPage{jobs: [_], next: nil}} = Zizq.list_jobs(name)
    end
  end

  describe "count_jobs/2" do
    test "returns the count" do
      name = server(200, ~s({"count":1284}))

      assert Zizq.count_jobs(name) == {:ok, 1284}
      assert_receive {:request, "GET", "/jobs/count", _}
    end

    test "takes the same filters as a listing" do
      name = server(200, ~s({"count":3}))

      Zizq.count_jobs([queue: "emails", attempts: [min: 1]], name)

      assert_receive {:request, "GET", "/jobs/count", query}
      params = URI.decode_query(query)

      assert params["queue"] == "emails"
      assert params["attempts"] == "1.."
    end

    test "the bang variant returns the number" do
      name = server(200, ~s({"count":7}))

      assert Zizq.count_jobs!([queue: "emails"], name) == 7
    end

    test "an error is an error" do
      name = server(422, ~s({"error":"bad filter"}))

      assert {:error, %Zizq.Error{reason: :invalid_request}} = Zizq.count_jobs(name)
    end
  end

  describe "list_queues/1" do
    test "returns the queue names" do
      name = server(200, ~s({"queues":["default","emails"]}))

      assert Zizq.list_queues(name) == {:ok, ["default", "emails"]}
      assert_receive {:request, "GET", "/queues", _}
    end

    test "the bang variant returns the list" do
      name = server(200, ~s({"queues":[]}))

      assert Zizq.list_queues!(name) == []
    end
  end
end
