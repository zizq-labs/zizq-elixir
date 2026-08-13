# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.BulkTest do
  @moduledoc """
  Changing and deleting many jobs at once.

  Selection rides in the query string and the changes in the body, so
  both halves are asserted: an operation that filtered correctly but
  patched the wrong fields looks the same from either side alone.
  """

  use ExUnit.Case, async: true

  alias Zizq.FakeServer

  defp server(status, body) do
    test_pid = self()

    FakeServer.start_client!(
      fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        decoded = if raw == "", do: nil, else: JSON.decode!(raw)
        send(test_pid, {:request, conn.method, conn.query_string, decoded})

        FakeServer.respond(conn, status, "application/json", body)
      end,
      format: :json
    )
  end

  describe "update_all_jobs/3" do
    test "returns how many were changed" do
      name = server(200, ~s({"patched":42}))

      assert Zizq.update_all_jobs([where: [queue: "emails"], apply: [priority: 0]], name) ==
               {:ok, 42}
    end

    test "filters go in the query and changes in the body" do
      name = server(200, ~s({"patched":1}))

      Zizq.update_all_jobs(
        [where: [queue: "emails", status: :scheduled], apply: [priority: 0, ready_at: nil]],
        name
      )

      assert_receive {:request, "PATCH", query, body}
      params = URI.decode_query(query)

      assert params["queue"] == "emails"
      assert params["status"] == "scheduled"
      assert body == %{"priority" => 0, "ready_at" => nil}
    end

    # The same merge-patch rules as a single job: `nil` is sent to
    # clear, an omitted field is absent entirely.
    test "clears with nil and leaves omitted fields out" do
      name = server(200, ~s({"patched":1}))

      Zizq.update_all_jobs([where: [queue: "emails"], apply: [retry_limit: nil]], name)

      assert_receive {:request, "PATCH", _query, body}
      assert body == %{"retry_limit" => nil}
    end

    # Finished jobs are not editable, and the server answers 422. This
    # is knowable here, so it does not cost a round trip.
    test "a terminal status filter is rejected before the request" do
      name = server(200, ~s({"patched":0}))

      for status <- [:completed, :dead] do
        assert_raise ArgumentError, ~r/not editable/, fn ->
          Zizq.update_all_jobs([where: [status: status], apply: [priority: 1]], name)
        end
      end

      assert_raise ArgumentError, ~r/not editable/, fn ->
        Zizq.update_all_jobs([where: [status: [:ready, :dead]], apply: [priority: 1]], name)
      end

      refute_receive {:request, _, _, _}
    end

    test "a runnable status filter is fine" do
      name = server(200, ~s({"patched":3}))

      assert {:ok, 3} =
               Zizq.update_all_jobs(
                 [where: [status: [:ready, :scheduled]], apply: [priority: 1]],
                 name
               )
    end

    test "an empty change set is rejected" do
      name = server(200, ~s({"patched":0}))

      assert_raise ArgumentError, ~r/at least one field/, fn ->
        Zizq.update_all_jobs([where: [queue: "emails"], apply: []], name)
      end
    end

    test "an unknown filter or change is rejected" do
      name = server(200, ~s({"patched":0}))

      assert_raise ArgumentError, ~r/unknown filter/, fn ->
        Zizq.update_all_jobs([where: [queeue: "emails"], apply: [priority: 1]], name)
      end

      assert_raise ArgumentError, ~r/unknown update key/, fn ->
        Zizq.update_all_jobs([where: [queue: "emails"], apply: [priorty: 1]], name)
      end
    end

    # No filters is a valid request that changes everything, so it must
    # reach the server rather than being second-guessed here.
    test "no filters sends no restriction" do
      name = server(200, ~s({"patched":9}))

      assert {:ok, 9} = Zizq.update_all_jobs([apply: [priority: 1]], name)
      assert_receive {:request, "PATCH", "", _}
    end

    test ":apply is required, since a change set is the point" do
      name = server(200, ~s({"patched":0}))

      assert_raise ArgumentError, ~r/needs :apply/, fn ->
        Zizq.update_all_jobs([where: [queue: "emails"]], name)
      end
    end

    # The mistake the names exist to prevent: both halves are keyword
    # lists sharing keys, so a transposition could succeed.
    test "positional-looking options are rejected" do
      name = server(200, ~s({"patched":0}))

      assert_raise ArgumentError, ~r/takes :where and :apply/, fn ->
        Zizq.update_all_jobs([queue: "emails", priority: 0], name)
      end
    end

    test "the bang variant returns the count" do
      name = server(200, ~s({"patched":5}))

      assert Zizq.update_all_jobs!([where: [queue: "emails"], apply: [priority: 1]], name) == 5
    end

    test "an error is an error" do
      name = server(422, ~s({"error":"nope"}))

      assert {:error, %Zizq.Error{reason: :invalid_request}} =
               Zizq.update_all_jobs([where: [queue: "emails"], apply: [priority: 1]], name)
    end
  end

  describe "delete_all_jobs/2" do
    test "returns how many were deleted" do
      name = server(200, ~s({"deleted":17}))

      assert Zizq.delete_all_jobs([queue: "emails", status: :dead], name) == {:ok, 17}
    end

    test "filters go in the query string" do
      name = server(200, ~s({"deleted":1}))

      Zizq.delete_all_jobs([queue: "emails", attempts: [min: 3]], name)

      assert_receive {:request, "DELETE", query, _body}
      params = URI.decode_query(query)

      assert params["queue"] == "emails"
      assert params["attempts"] == "3.."
    end

    # Unlike a patch, deleting a finished job is meaningful — clearing
    # out dead jobs is the obvious reason to reach for this.
    test "a terminal status is allowed here" do
      name = server(200, ~s({"deleted":4}))

      assert {:ok, 4} = Zizq.delete_all_jobs([status: :dead], name)
    end

    test "no filters deletes everything, and says nothing about it" do
      name = server(200, ~s({"deleted":100}))

      assert {:ok, 100} = Zizq.delete_all_jobs(name)
      assert_receive {:request, "DELETE", "", _}
    end

    test "an unknown filter is rejected" do
      name = server(200, ~s({"deleted":0}))

      assert_raise ArgumentError, ~r/unknown filter/, fn ->
        Zizq.delete_all_jobs([queeue: "emails"], name)
      end
    end

    test "the bang variant returns the count" do
      name = server(200, ~s({"deleted":2}))

      assert Zizq.delete_all_jobs!([queue: "emails"], name) == 2
    end
  end
end
