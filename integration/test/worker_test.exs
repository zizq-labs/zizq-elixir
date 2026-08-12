defmodule Zizq.Integration.WorkerTest do
  @moduledoc """
  A worker against a real server: jobs enqueued, consumed, and the
  outcome confirmed by asking the server what it recorded.
  """

  use ExUnit.Case, async: false

  @moduletag capture_log: true

  setup do
    url = System.fetch_env!("ZIZQ_URL")
    start_supervised!({Zizq, name: :wk, url: url})
    %{url: url, queue: "wk_#{System.unique_integer([:positive])}"}
  end

  defp enqueue!(ctx, opts \\ []) do
    opts
    |> Keyword.merge(type: "probe", queue: ctx.queue)
    # Completed jobs are purged immediately by default, and these tests
    # need to look at them afterwards.
    |> Keyword.put_new(:retention, completed: :timer.minutes(5))
    |> Zizq.enqueue!(:wk)
  end

  defp start_worker!(ctx, handler, opts \\ []) do
    opts =
      Keyword.merge(
        [
          client: :wk,
          handler: handler,
          queues: [ctx.queue],
          name: :"wk_#{System.unique_integer([:positive])}",
          drain_timeout: 2_000
        ],
        opts
      )

    start_supervised!({Zizq.Worker, opts})
  end

  defp eventually(condition, timeout \\ 10_000) do
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
        Process.sleep(50)
        poll(condition, deadline)
    end
  end

  test "runs enqueued jobs and completes them", ctx do
    test_pid = self()
    jobs = for n <- 1..10, do: enqueue!(ctx, payload: %{"n" => n})

    start_worker!(ctx, fn job ->
      send(test_pid, {:ran, job.payload["n"]})
      :ok
    end)

    received =
      for _ <- 1..10 do
        assert_receive {:ran, n}, 10_000
        n
      end

    assert Enum.sort(received) == Enum.to_list(1..10)

    eventually(fn ->
      Enum.all?(jobs, &(Zizq.get_job!(&1.id, :wk).status == :completed))
    end)
  end

  test "runs jobs concurrently", ctx do
    test_pid = self()
    for n <- 1..5, do: enqueue!(ctx, payload: %{"n" => n})

    start_worker!(
      ctx,
      fn _job ->
        send(test_pid, {:started, self()})

        receive do
          :finish -> :ok
        after
          5_000 -> :ok
        end
      end,
      concurrency: 5
    )

    # All five in flight at once, which only holds if they really run
    # in parallel.
    pids =
      for _ <- 1..5 do
        assert_receive {:started, pid}, 10_000
        pid
      end

    assert length(Enum.uniq(pids)) == 5
    for pid <- pids, do: send(pid, :finish)
  end

  test "a failing handler leaves the job for another attempt", ctx do
    job = enqueue!(ctx, retry_limit: 5)

    start_worker!(ctx, fn _job -> {:error, "SMTP timeout"} end)

    eventually(fn ->
      stored = Zizq.get_job!(job.id, :wk)
      stored.attempts == 1 and stored.status == :scheduled
    end)
  end

  test "a raising handler records the exception", ctx do
    job = enqueue!(ctx, retry_limit: 5)

    start_worker!(ctx, fn _job -> raise ArgumentError, "handler blew up" end)

    eventually(fn -> Zizq.get_job!(job.id, :wk).attempts == 1 end)

    {:ok, {{_, 200, _}, _, body}} =
      :httpc.request(
        :get,
        {~c"#{ctx.url}/jobs/#{job.id}/errors", [{~c"accept", ~c"application/json"}]},
        [],
        body_format: :binary
      )

    assert [error | _] = JSON.decode!(body)["errors"]
    assert error["message"] == "handler blew up"
    assert error["error_type"] == "ArgumentError"
    assert error["backtrace"] =~ "worker_test.exs"
  end

  test "{:cancel, reason} kills the job outright", ctx do
    job = enqueue!(ctx, retry_limit: 25, retention: [dead: :timer.minutes(5)])

    start_worker!(ctx, fn _job -> {:cancel, :customer_deleted} end)

    eventually(fn -> Zizq.get_job!(job.id, :wk).status == :dead end)
  end

  test "{:snooze, milliseconds} defers the job", ctx do
    job = enqueue!(ctx)

    start_worker!(ctx, fn _job -> {:snooze, :timer.hours(1)} end)

    eventually(fn ->
      stored = Zizq.get_job!(job.id, :wk)

      stored.status == :scheduled and
        DateTime.to_unix(stored.ready_at, :millisecond) >
          System.system_time(:millisecond) + 3_000_000
    end)
  end

  # The ordering the supervision tree exists for: a job still running
  # when shutdown starts is finished and acknowledged, rather than
  # abandoned and redelivered.
  test "shutdown completes work already in progress", ctx do
    test_pid = self()
    job = enqueue!(ctx)

    {:ok, worker} =
      Zizq.Worker.start_link(
        client: :wk,
        queues: [ctx.queue],
        drain_timeout: 5_000,
        name: :"wk_drain_#{System.unique_integer([:positive])}",
        handler: fn j ->
          send(test_pid, {:started, j.id, self()})

          receive do
            :finish -> :ok
          after
            5_000 -> :ok
          end
        end
      )

    assert_receive {:started, _, handler}, 10_000

    stopper = Task.async(fn -> Supervisor.stop(worker) end)
    send(handler, :finish)
    Task.await(stopper, 10_000)

    # Completed, not left in flight for redelivery.
    assert Zizq.get_job!(job.id, :wk).status == :completed
  end
end
