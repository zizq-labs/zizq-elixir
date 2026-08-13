# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.ErrorsTest do
  @moduledoc """
  Reading a job's failure history.

  Error listings paginate through the same links a job listing does,
  so the paging clauses are exercised here too — decoding a page of
  errors as a page of jobs would otherwise be a silent mistake.
  """

  use ExUnit.Case, async: true

  alias Zizq.FakeServer

  defp server(status, body) do
    test_pid = self()

    FakeServer.start_client!(
      fn conn ->
        send(test_pid, {:request, conn.request_path, conn.query_string})
        FakeServer.respond(conn, status, "application/json", body)
      end,
      format: :json
    )
  end

  defp record(attempt, overrides \\ %{}) do
    Map.merge(
      %{
        "attempt" => attempt,
        "message" => "SMTP timeout",
        "dequeued_at" => 1_700_000_000_000,
        "failed_at" => 1_700_000_002_500
      },
      overrides
    )
  end

  defp page(records, pages \\ %{}) do
    JSON.encode!(%{"errors" => records, "pages" => pages})
  end

  describe "list_errors/3" do
    test "returns the failed attempts" do
      name = server(200, page([record(1), record(2)]))

      assert {:ok, %Zizq.ErrorPage{errors: [first, second]}} = Zizq.list_errors("a", name)

      assert %Zizq.ErrorRecord{attempt: 1, message: "SMTP timeout"} = first
      assert second.attempt == 2
      assert_receive {:request, "/jobs/a/errors", _}
    end

    test "takes a job as well as an id" do
      name = server(200, page([]))

      Zizq.list_errors(%Zizq.Job{id: "a"}, name)

      assert_receive {:request, "/jobs/a/errors", _}
    end

    test "timestamps arrive as DateTimes" do
      name = server(200, page([record(1)]))

      {:ok, %{errors: [error]}} = Zizq.list_errors("a", name)

      assert %DateTime{} = error.dequeued_at
      assert %DateTime{} = error.failed_at
    end

    test "optional fields survive being absent" do
      name = server(200, page([record(1)]))

      {:ok, %{errors: [error]}} = Zizq.list_errors("a", name)

      assert error.error_type == nil
      assert error.backtrace == nil
    end

    test "optional fields arrive when the worker reported them" do
      name =
        server(
          200,
          page([record(1, %{"error_type" => "ArgumentError", "backtrace" => "line one"})])
        )

      {:ok, %{errors: [error]}} = Zizq.list_errors("a", name)

      assert error.error_type == "ArgumentError"
      assert error.backtrace == "line one"
    end

    test "limit and order are sent" do
      name = server(200, page([]))

      Zizq.list_errors("a", name, limit: 10, order: :desc)

      assert_receive {:request, "/jobs/a/errors", query}
      params = URI.decode_query(query)

      assert params["limit"] == "10"
      assert params["order"] == "desc"
    end

    test "the bang variant raises" do
      name = server(404, ~s({"error":"no such job"}))

      assert_raise Zizq.Error, fn -> Zizq.list_errors!("gone", name) end
    end
  end

  describe "paging an error listing" do
    # The reason `next_page/2` dispatches on the page rather than
    # assuming jobs: this body has no "jobs" key at all.
    test "next_page decodes errors, not jobs" do
      name = server(200, page([record(1)], %{"next" => "/jobs/a/errors?from=1"}))

      {:ok, page} = Zizq.list_errors("a", name)
      assert Zizq.ErrorPage.has_next?(page)

      assert {:ok, %Zizq.ErrorPage{errors: [%Zizq.ErrorRecord{}]}} = Zizq.next_page(page, name)
      assert_receive {:request, "/jobs/a/errors", "from=1"}
    end

    test "the last page has no next" do
      name = server(200, page([record(1)]))

      {:ok, page} = Zizq.list_errors("a", name)

      refute Zizq.ErrorPage.has_next?(page)
      assert Zizq.next_page(page, name) == {:ok, nil}
    end

    test "prev_page works the same way" do
      name = server(200, page([record(2)], %{"prev" => "/jobs/a/errors?before=2"}))

      {:ok, page} = Zizq.list_errors("a", name)
      assert Zizq.ErrorPage.has_prev?(page)

      assert {:ok, %Zizq.ErrorPage{}} = Zizq.prev_page(page, name)
    end
  end

  describe "get_error/3" do
    test "returns one attempt's error" do
      name = server(200, JSON.encode!(record(2, %{"message" => "boom"})))

      assert {:ok, %Zizq.ErrorRecord{attempt: 2, message: "boom"}} =
               Zizq.get_error("a", 2, name)

      assert_receive {:request, "/jobs/a/errors/2", _}
    end

    test "an attempt that did not fail is :not_found" do
      name = server(404, ~s({"error":"no such attempt"}))

      assert {:error, %Zizq.Error{reason: :not_found}} = Zizq.get_error("a", 9, name)
    end

    test "the bang variant raises" do
      name = server(404, ~s({"error":"nope"}))

      assert_raise Zizq.Error, fn -> Zizq.get_error!("a", 9, name) end
    end
  end

  describe "duration/1" do
    test "reports how long the attempt ran" do
      name = server(200, page([record(1)]))

      {:ok, %{errors: [error]}} = Zizq.list_errors("a", name)

      assert Zizq.ErrorRecord.duration(error) == 2_500
    end

    test "is nil when a timestamp is missing" do
      assert Zizq.ErrorRecord.duration(%Zizq.ErrorRecord{failed_at: DateTime.utc_now()}) == nil
      assert Zizq.ErrorRecord.duration(%Zizq.ErrorRecord{dequeued_at: DateTime.utc_now()}) == nil
    end
  end
end
