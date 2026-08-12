# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.WorkerTest do
  @moduledoc """
  The worker against an in-process server that streams jobs on command,
  so dispatch, the handler contract and shutdown can each be provoked
  rather than waited for.
  """

  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias Zizq.FakeServer

  defp start_server!, do: FakeServer.start_worker_client!()

  defp worker_opts(name, handler, opts) do
    Keyword.merge(
      [
        client: name,
        handler: handler,
        name: :"worker_#{System.unique_integer([:positive])}",
        # Tests that leave a handler blocked would otherwise wait out
        # the full 30s default at teardown.
        drain_timeout: 500
      ],
      opts
    )
  end

  defp start_worker!(name, handler, opts \\ []) do
    start_supervised!({Zizq.Worker, worker_opts(name, handler, opts)})
  end

  describe "the handler contract" do
    setup do
      test_pid = self()

      # The handler runs in a task, so it hands back its own pid and
      # waits there — the test cannot otherwise reach it.
      handler = fn job ->
        send(test_pid, {:handled, job.id, self()})

        receive do
          {:return, value} -> value
        after
          2_000 -> :ok
        end
      end

      %{name: start_server!(), handler: handler}
    end

    test ":ok acknowledges the job", ctx do
      start_worker!(ctx.name, ctx.handler)
      assert_receive {:stream, server}

      FakeServer.emit_job(server, "a")
      assert_receive {:handled, "a", handler}
      send(handler, {:return, :ok})

      assert_receive {:ack, "/jobs/success", %{"ids" => ["a"]}}
    end

    test "{:ok, value} acknowledges too", ctx do
      start_worker!(ctx.name, ctx.handler)
      assert_receive {:stream, server}

      FakeServer.emit_job(server, "a")
      assert_receive {:handled, "a", handler}
      send(handler, {:return, {:ok, %{whatever: true}}})

      assert_receive {:ack, "/jobs/success", %{"ids" => ["a"]}}
    end

    # Acknowledged rather than failed: the handler most likely did its
    # work and ended on the wrong value, so failing would re-run a side
    # effect that already happened.
    test "an unrecognised return value is acknowledged, and warned about", ctx do
      import ExUnit.CaptureLog

      start_worker!(ctx.name, ctx.handler)
      assert_receive {:stream, server}

      log =
        capture_log(fn ->
          FakeServer.emit_job(server, "a")
          assert_receive {:handled, "a", handler}
          send(handler, {:return, %{rows: 1}})

          assert_receive {:ack, "/jobs/success", %{"ids" => ["a"]}}
        end)

      assert log =~ "expected the handler for job a"
      assert log =~ "acknowledged as complete"
    end

    # The case the warning exists for: `:error` in place of
    # `{:error, reason}` would otherwise complete every job in a queue
    # while looking perfectly healthy.
    test "a bare :error is warned about rather than mistaken for failure", ctx do
      import ExUnit.CaptureLog

      start_worker!(ctx.name, ctx.handler)
      assert_receive {:stream, server}

      log =
        capture_log(fn ->
          FakeServer.emit_job(server, "a")
          assert_receive {:handled, "a", handler}
          send(handler, {:return, :error})

          assert_receive {:ack, "/jobs/success", %{"ids" => ["a"]}}
        end)

      assert log =~ ":error"
      assert log =~ "acknowledged as complete"
    end

    # Indistinguishable in shape from a legitimate return value, which
    # is why the warning cannot be conditional on how the value looks.
    test "a misspelled outcome tag is warned about too", ctx do
      import ExUnit.CaptureLog

      start_worker!(ctx.name, ctx.handler)
      assert_receive {:stream, server}

      log =
        capture_log(fn ->
          FakeServer.emit_job(server, "a")
          assert_receive {:handled, "a", handler}
          send(handler, {:return, {:eror, "typo"}})

          assert_receive {:ack, "/jobs/success", %{"ids" => ["a"]}}
        end)

      assert log =~ "eror"
    end

    test "{:error, reason} reports a failure", ctx do
      start_worker!(ctx.name, ctx.handler)
      assert_receive {:stream, server}

      FakeServer.emit_job(server, "a")
      assert_receive {:handled, "a", handler}
      send(handler, {:return, {:error, "SMTP timeout"}})

      assert_receive {:ack, "/jobs/a/failure", body}
      assert body["message"] == "SMTP timeout"
      refute Map.has_key?(body, "kill")
    end

    test "{:cancel, reason} kills the job", ctx do
      start_worker!(ctx.name, ctx.handler)
      assert_receive {:stream, server}

      FakeServer.emit_job(server, "a")
      assert_receive {:handled, "a", handler}
      send(handler, {:return, {:cancel, :customer_deleted}})

      assert_receive {:ack, "/jobs/a/failure", body}
      assert body["kill"] == true
      assert body["message"] =~ "customer_deleted"
    end

    # Milliseconds, as everywhere else in this client — a minute here is
    # 60_000, not 60.
    test "{:snooze, milliseconds} reschedules it", ctx do
      start_worker!(ctx.name, ctx.handler)
      assert_receive {:stream, server}

      FakeServer.emit_job(server, "a")
      assert_receive {:handled, "a", handler}
      send(handler, {:return, {:snooze, :timer.minutes(1)}})

      assert_receive {:ack, "/jobs/a/failure", body}
      assert is_integer(body["retry_at"])
      # Roughly a minute out; the exact instant depends on when the
      # handler returned. The lower bound also pins the unit: read as
      # seconds this would be 60ms from now and would fail here.
      assert body["retry_at"] > System.system_time(:millisecond) + 50_000
    end

    test "{:snooze, %DateTime{}} reschedules to that instant", ctx do
      start_worker!(ctx.name, ctx.handler)
      assert_receive {:stream, server}

      at = DateTime.add(DateTime.utc_now(), 3_600, :second)

      FakeServer.emit_job(server, "a")
      assert_receive {:handled, "a", handler}
      send(handler, {:return, {:snooze, at}})

      assert_receive {:ack, "/jobs/a/failure", body}
      assert body["retry_at"] == DateTime.to_unix(at, :millisecond)
    end
  end

  describe "crashing handlers" do
    test "a raise becomes a failure, with the exception and stacktrace" do
      name = start_server!()
      start_worker!(name, fn _job -> raise ArgumentError, "handler blew up" end)

      assert_receive {:stream, server}
      FakeServer.emit_job(server, "a")

      assert_receive {:ack, "/jobs/a/failure", body}
      assert body["message"] == "handler blew up"
      assert body["error_type"] == "ArgumentError"
      assert body["backtrace"] =~ "worker_test.exs"
    end

    test "an exit becomes a failure" do
      name = start_server!()
      start_worker!(name, fn _job -> exit(:something_went_wrong) end)

      assert_receive {:stream, server}
      FakeServer.emit_job(server, "a")

      assert_receive {:ack, "/jobs/a/failure", body}
      assert body["message"] =~ "something_went_wrong"
    end

    # The property that makes per-job tasks worth it.
    test "a crashing handler does not stop the worker" do
      name = start_server!()
      test_pid = self()

      start_worker!(name, fn job ->
        if job.id == "boom", do: raise("nope")
        send(test_pid, {:survived, job.id})
        :ok
      end)

      assert_receive {:stream, server}

      FakeServer.emit_job(server, "boom")
      assert_receive {:ack, "/jobs/boom/failure", _}

      FakeServer.emit_job(server, "after")
      assert_receive {:survived, "after"}
    end
  end

  describe "concurrency" do
    test "runs no more than :concurrency jobs at once" do
      name = start_server!()
      test_pid = self()

      start_worker!(
        name,
        fn job ->
          send(test_pid, {:started, job.id, self()})

          receive do
            :finish -> :ok
          after
            1_000 -> :ok
          end
        end,
        concurrency: 2
      )

      assert_receive {:stream, server}
      for id <- ["a", "b", "c", "d"], do: FakeServer.emit_job(server, id)

      assert_receive {:started, _, first}
      assert_receive {:started, _, second}

      # The remaining two wait for a slot rather than all starting at
      # once. Prefetch still delivered them; the worker holds them.
      refute_receive {:started, _, _}, 300

      # Every one released before the test ends, so teardown is not
      # left draining blocked handlers and logging about it outside log
      # capture. Freeing the first two starts the queued two, so those
      # have to be collected as well.
      for pid <- [first, second], do: send(pid, :finish)

      for _ <- 1..2 do
        assert_receive {:started, _, pid}
        send(pid, :finish)
      end
    end

    test "starts a queued job as soon as a slot frees" do
      name = start_server!()
      test_pid = self()

      start_worker!(
        name,
        fn job ->
          send(test_pid, {:started, job.id, self()})

          receive do
            :finish -> :ok
          after
            1_000 -> :ok
          end
        end,
        concurrency: 1
      )

      assert_receive {:stream, server}
      FakeServer.emit_job(server, "a")
      FakeServer.emit_job(server, "b")

      assert_receive {:started, "a", first}
      refute_receive {:started, "b", _}, 200

      send(first, :finish)
      assert_receive {:started, "b", second}
      send(second, :finish)
    end
  end

  describe "shutdown" do
    # The ordering the whole supervision tree is arranged for: a job
    # still running when shutdown begins is allowed to finish, and its
    # acknowledgement reaches the server while the stream is still
    # open to accept it.
    test "waits for a running job and acknowledges it before stopping" do
      name = start_server!()
      test_pid = self()

      handler = fn job ->
        send(test_pid, {:started, job.id, self()})

        receive do
          :finish -> :ok
        after
          5_000 -> :ok
        end
      end

      {:ok, worker} =
        Zizq.Worker.start_link(worker_opts(name, handler, drain_timeout: 5_000))

      assert_receive {:stream, server}
      FakeServer.emit_job(server, "a")
      assert_receive {:started, "a", handler_pid}

      # Stopping blocks until the drain completes, so it runs
      # elsewhere while this process observes what happens.
      stopper = Task.async(fn -> Supervisor.stop(worker) end)

      # Not finished yet, so shutdown must still be waiting.
      refute_receive {:ack, "/jobs/success", _}, 200

      send(handler_pid, :finish)

      # Acknowledged during shutdown, not dropped.
      assert_receive {:ack, "/jobs/success", %{"ids" => ["a"]}}
      Task.await(stopper, 5_000)
    end

    # Acking during the drain frees prefetch slots, so the server
    # naturally sends more work while we are shutting down. It has to be
    # left alone: starting it would extend a shutdown that is supposed
    # to be bounded, and the server redelivers it after its visibility
    # timeout regardless.
    test "ignores jobs that arrive while draining" do
      name = start_server!()
      test_pid = self()

      handler = fn job ->
        send(test_pid, {:started, job.id, self()})

        receive do
          :finish -> :ok
        after
          5_000 -> :ok
        end
      end

      {:ok, worker} = Zizq.Worker.start_link(worker_opts(name, handler, drain_timeout: 5_000))

      assert_receive {:stream, server}
      FakeServer.emit_job(server, "a")
      assert_receive {:started, "a", handler_pid}

      stopper = Task.async(fn -> Supervisor.stop(worker) end)

      # "a" is still blocked, so nothing can be acked yet. Asserting
      # that doubles as a barrier: by the time it expires, `terminate/2`
      # is underway, so "b" below genuinely arrives mid-drain rather
      # than landing in the pre-shutdown queue.
      refute_receive {:ack, _, _}, 200

      FakeServer.emit_job(server, "b")

      # The real assertion, and it has to happen here rather than after
      # the worker stops: "b" needs long enough to travel the stream and
      # reach the runner's mailbox *while the drain is still running*.
      # Checking once the process is already dead would pass whether or
      # not the drain ignores new work.
      refute_receive {:started, "b", _}, 200

      send(handler_pid, :finish)

      assert_receive {:ack, "/jobs/success", %{"ids" => ["a"]}}
      Task.await(stopper, 5_000)

      # Never acked either, so the server still holds it for redelivery.
      refute_received {:ack, "/jobs/success", %{"ids" => ["b"]}}
    end

    test "gives up at the drain timeout rather than hanging" do
      name = start_server!()
      test_pid = self()

      # Never returns on its own, so only the drain deadline can end
      # the shutdown.
      handler = fn job ->
        send(test_pid, {:started, job.id})
        Process.sleep(:infinity)
      end

      {:ok, worker} = Zizq.Worker.start_link(worker_opts(name, handler, drain_timeout: 300))

      assert_receive {:stream, server}
      FakeServer.emit_job(server, "a")
      assert_receive {:started, "a"}

      # A handler that never returns must not hold shutdown open. The
      # job is redelivered after its visibility timeout instead.
      stopper = Task.async(fn -> Supervisor.stop(worker) end)
      assert Task.await(stopper, 5_000) == :ok
    end

    test "stops cleanly when nothing is running" do
      name = start_server!()
      {:ok, worker} = Zizq.Worker.start_link(worker_opts(name, fn _ -> :ok end, []))

      assert_receive {:stream, _server}
      assert Supervisor.stop(worker) == :ok
    end
  end
end
