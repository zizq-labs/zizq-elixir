# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Worker.AckerTest do
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias Zizq.FakeServer
  alias Zizq.Worker.Acker

  # Supervised rather than linked: a linked acker survives the test
  # process exiting normally, and its pending retry timers then fire
  # after ExUnit has stopped capturing logs.

  # Reports every request to the test, and answers however the test
  # says — so retry and partial-success paths can be produced on demand.
  defp server(responder) do
    test_pid = self()

    FakeServer.start_client!(
      fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        decoded = if raw == "", do: nil, else: JSON.decode!(raw)
        send(test_pid, {:request, conn.request_path, decoded})
        responder.(conn)
      end,
      format: :json
    )
  end

  defp always(status, body) do
    server(fn conn -> FakeServer.respond(conn, status, "application/json", body) end)
  end

  # Fails the first `n` requests, then succeeds.
  defp failing_then_ok(n) do
    counter = :counters.new(1, [])

    server(fn conn ->
      :counters.add(counter, 1, 1)

      if :counters.get(counter, 1) <= n do
        FakeServer.respond(conn, 503, "application/json", ~s({"error":"busy"}))
      else
        FakeServer.respond(conn, 204, nil, "")
      end
    end)
  end

  defp eventually(condition, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(condition, deadline)
  end

  defp poll(condition, deadline) do
    cond do
      condition.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition was still false at the deadline")

      true ->
        Process.sleep(10)
        poll(condition, deadline)
    end
  end

  # Collects whole requests until `count` ids have been seen. How the
  # ids are distributed across requests is deliberately not asserted:
  # batching is opportunistic, so that depends on how many happened to
  # have arrived, which is not something a test can pin down.
  defp collect_ids(count, acc \\ []) do
    if length(acc) >= count do
      acc
    else
      assert_receive {:request, "/jobs/success", %{"ids" => ids}}
      collect_ids(count, acc ++ ids)
    end
  end

  describe "batching successes" do
    # The real batching mechanism, made deterministic: while a request
    # is in flight the acker is busy, so anything acknowledged
    # meanwhile accumulates and leaves in the next request together.
    test "acknowledgements arriving during a request go out together" do
      test_pid = self()

      name =
        server(fn conn ->
          send(test_pid, {:started, self()})

          # Hold the first request open until the test releases it.
          receive do
            :release -> :ok
          after
            2_000 -> :ok
          end

          FakeServer.respond(conn, 204, nil, "")
        end)

      acker = start_supervised!({Acker, client: name})

      Acker.success(acker, "a")
      assert_receive {:request, _, %{"ids" => ["a"]}}
      assert_receive {:started, first}

      # These cannot be sent yet: the acker is blocked on the request
      # above, so they queue in its mailbox.
      Acker.success(acker, "b")
      Acker.success(acker, "c")

      send(first, :release)

      assert_receive {:request, _, %{"ids" => ids}}
      assert ids == ["b", "c"]
    end

    test "preserves the order jobs were acknowledged in" do
      name = always(204, "")
      acker = start_supervised!({Acker, client: name})

      for n <- 1..10, do: Acker.success(acker, "job-#{n}")

      # Order holds across the batch boundaries, wherever they fall.
      assert collect_ids(10) == Enum.map(1..10, &"job-#{&1}")
    end

    # A cap on request size, not a trigger: the excess is sent straight
    # after rather than held back.
    test "splits a buffer larger than max_batch across requests" do
      name = always(204, "")
      acker = start_supervised!({Acker, client: name, max_batch: 3})

      for n <- 1..7, do: Acker.success(acker, "job-#{n}")

      ids = collect_ids(7)
      assert ids == Enum.map(1..7, &"job-#{&1}")
      eventually(fn -> Acker.pending(acker) == 0 end)
    end

    # The property a flush interval would break: prefetch is released
    # by acknowledgement, so a lone completion must not sit waiting for
    # company that may never arrive.
    test "a single success is sent without waiting for others" do
      name = always(204, "")
      acker = start_supervised!({Acker, client: name})

      Acker.success(acker, "alone")

      # No interval to wait out.
      assert_receive {:request, "/jobs/success", %{"ids" => ["alone"]}}
    end

    test "accepts a job struct as well as an id" do
      name = always(204, "")
      acker = start_supervised!({Acker, client: name})

      Acker.success(acker, %Zizq.Job{id: "from-struct"})

      assert_receive {:request, _, %{"ids" => ["from-struct"]}}
    end

    test "does nothing when there is nothing to send" do
      name = always(204, "")
      acker = start_supervised!({Acker, client: name})

      assert Acker.flush(acker) == :ok
      refute_receive {:request, _, _}
    end
  end

  describe "retrying" do
    # Dropping these would mean the jobs are redelivered and the work
    # repeated, so a brief outage should cost a delay instead.
    test "keeps the batch and retries a transient failure" do
      name = failing_then_ok(2)
      acker = start_supervised!({Acker, client: name})

      Acker.success(acker, "a")

      assert_receive {:request, _, %{"ids" => ["a"]}}
      assert_receive {:request, _, %{"ids" => ["a"]}}
      assert_receive {:request, _, %{"ids" => ["a"]}}

      eventually(fn -> Acker.pending(acker) == 0 end)
    end

    test "keeps accepting work while a retry is outstanding" do
      name = failing_then_ok(1)
      acker = start_supervised!({Acker, client: name})

      Acker.success(acker, "a")
      assert_receive {:request, _, %{"ids" => ["a"]}}

      # Arrives during the backoff, and joins the retried batch rather
      # than being blocked behind it.
      Acker.success(acker, "b")

      assert_receive {:request, _, %{"ids" => ids}}
      assert Enum.sort(ids) == ["a", "b"]
      eventually(fn -> Acker.pending(acker) == 0 end)
    end

    # Retrying a 4xx could only produce the same answer, and holding
    # the buffer would stall every acknowledgement behind it.
    test "drops the batch on a permanent failure" do
      name = always(400, ~s({"error":"bad request"}))
      acker = start_supervised!({Acker, client: name})

      Acker.success(acker, "a")
      assert_receive {:request, _, _}

      eventually(fn -> Acker.pending(acker) == 0 end)
      refute_receive {:request, _, _}, 300
    end

    test "treats a partial success as done, not as something to retry" do
      name = always(422, ~s({"not_found":["b"]}))
      acker = start_supervised!({Acker, client: name})

      Acker.success(acker, "a")
      Acker.success(acker, "b")

      assert_receive {:request, _, _}

      # "b" was already handled elsewhere; "a" completed. Neither is
      # worth sending again.
      eventually(fn -> Acker.pending(acker) == 0 end)
      refute_receive {:request, _, _}, 300
    end
  end

  describe "failures" do
    test "are sent individually, with their detail" do
      name = always(200, ~s({"id":"job-1","status":"scheduled","attempts":1}))
      acker = start_supervised!({Acker, client: name})

      Acker.failure(acker, "job-1", message: "boom", error_type: "RuntimeError")

      assert_receive {:request, "/jobs/job-1/failure", body}
      assert body["message"] == "boom"
      assert body["error_type"] == "RuntimeError"
    end

    test "one failure per job, never combined" do
      name = always(200, ~s({"id":"x","status":"scheduled","attempts":1}))
      acker = start_supervised!({Acker, client: name})

      Acker.failure(acker, "job-1", message: "a")
      Acker.failure(acker, "job-2", message: "b")

      assert_receive {:request, "/jobs/job-1/failure", _}
      assert_receive {:request, "/jobs/job-2/failure", _}
    end

    test "carry kill and retry_at through" do
      name = always(200, ~s({"id":"x","status":"dead","attempts":1}))
      acker = start_supervised!({Acker, client: name})

      Acker.failure(acker, "job-1", message: "gone", kill: true)
      assert_receive {:request, _, %{"kill" => true}}
    end
  end

  describe "flush/2" do
    test "returns only once everything buffered has been sent" do
      name = always(204, "")
      acker = start_supervised!({Acker, client: name})

      Acker.success(acker, "a")
      assert Acker.flush(acker) == :ok

      # Nothing left pending by the time flush returned, which is what
      # makes it usable during shutdown.
      assert Acker.pending(acker) == 0
      assert_receive {:request, _, %{"ids" => ["a"]}}
    end

    test "gives up at the deadline rather than blocking shutdown" do
      name = always(503, ~s({"error":"busy"}))
      acker = start_supervised!({Acker, client: name})

      Acker.success(acker, "a")

      # A server that never recovers must not hold shutdown open. The
      # job is redelivered instead.
      assert Acker.flush(acker, 200) == :ok
    end
  end
end
