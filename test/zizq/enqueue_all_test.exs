# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.EnqueueAllTest do
  @moduledoc """
  Bulk enqueue against the in-process fake server, so the request shape
  and the 200/201 handling can be checked without a real one.
  """

  use ExUnit.Case, async: true

  alias Zizq.FakeServer

  defp responding_with(status, jobs) do
    test_pid = self()

    FakeServer.start_client!(
      fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, conn.request_path, JSON.decode!(body)})
        FakeServer.respond(conn, status, "application/json", JSON.encode!(%{"jobs" => jobs}))
      end,
      format: :json
    )
  end

  defp job(id), do: %{"id" => id, "type" => "probe", "queue" => "default", "status" => "ready"}

  test "posts every job to the bulk endpoint in order" do
    name = responding_with(201, [job("a"), job("b")])

    assert {:ok, [first, second]} =
             Zizq.enqueue_all(
               [
                 [type: "one", payload: %{"n" => 1}],
                 [type: "two", payload: %{"n" => 2}]
               ],
               name
             )

    assert first.id == "a"
    assert second.id == "b"

    assert_receive {:request, "/jobs/bulk", %{"jobs" => sent}}
    assert length(sent) == 2
    assert Enum.map(sent, & &1["type"]) == ["one", "two"]
    assert Enum.map(sent, & &1["payload"]) == [%{"n" => 1}, %{"n" => 2}]
  end

  # The server answers 200 rather than 201 when every job turned out to
  # be a duplicate or was folded into an existing batch, so nothing new
  # was created. Both are success.
  test "treats 200 as success, not just 201" do
    name = responding_with(200, [job("a")])

    assert {:ok, [decoded]} = Zizq.enqueue_all([[type: "one"]], name)
    assert decoded.id == "a"
  end

  test "accepts structs, maps and keyword lists interchangeably" do
    name = responding_with(201, [job("a"), job("b"), job("c")])

    assert {:ok, jobs} =
             Zizq.enqueue_all(
               [Zizq.Enqueue.new!(type: "one"), %{type: "two"}, [type: "three"]],
               name
             )

    assert length(jobs) == 3
    assert_receive {:request, _, %{"jobs" => sent}}
    assert Enum.map(sent, & &1["type"]) == ["one", "two", "three"]
  end

  test "answers an empty list without contacting the server" do
    name = responding_with(201, [])

    assert Zizq.enqueue_all([], name) == {:ok, []}
    refute_receive {:request, _, _}
  end

  # Matches how the server reports its own per-job failures, so the two
  # read the same whichever side rejects first.
  test "names the offending index when a job is invalid" do
    name = responding_with(201, [])

    error =
      assert_raise ArgumentError, fn ->
        Zizq.enqueue_all([[type: "ok"], [type: "ok"], [type: nil]], name)
      end

    assert Exception.message(error) =~ "jobs[2]:"
    assert Exception.message(error) =~ ":type is required"
    refute_receive {:request, _, _}
  end

  test "surfaces a server rejection as an error" do
    name =
      FakeServer.start_client!(
        fn conn ->
          FakeServer.respond(
            conn,
            400,
            "application/json",
            ~s({"error":"jobs[0]: invalid queue name"})
          )
        end,
        format: :json
      )

    assert {:error, %Zizq.Error{reason: :invalid_request} = error} =
             Zizq.enqueue_all([[type: "one", queue: "a,b"]], name)

    assert Exception.message(error) =~ "jobs[0]: invalid queue name"
  end

  test "enqueue_all!/2 raises that error" do
    name =
      FakeServer.start_client!(
        fn conn -> FakeServer.respond(conn, 500, "application/json", ~s({"error":"boom"})) end,
        format: :json
      )

    assert_raise Zizq.Error, ~r/server returned 500: boom/, fn ->
      Zizq.enqueue_all!([[type: "one"]], name)
    end
  end
end
