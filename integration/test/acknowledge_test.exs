defmodule Zizq.Integration.AcknowledgeTest do
  @moduledoc """
  The full lifecycle against a real server: enqueue, take, acknowledge,
  and confirm the server agrees on what happened.
  """

  use ExUnit.Case, async: false

  @moduletag capture_log: true

  setup do
    url = System.fetch_env!("ZIZQ_URL")
    start_supervised!({Zizq, name: :ack, url: url})
    %{url: url, queue: "ack_#{System.unique_integer([:positive])}"}
  end

  # Completed jobs are purged the moment they complete unless a
  # retention is set (the server's default for `completed` is 0), so
  # anything that wants to *look* at a completed job has to ask for it
  # to be kept.
  defp enqueue_retained!(ctx, opts \\ []) do
    opts
    |> Keyword.merge(type: "probe", queue: ctx.queue)
    |> Keyword.put_new(:retention, completed: :timer.minutes(5))
    |> Zizq.enqueue!(:ack)
  end

  defp fetch_job!(url, id) do
    {:ok, {{_, 200, _}, _headers, body}} =
      :httpc.request(
        :get,
        {~c"#{url}/jobs/#{id}", [{~c"accept", ~c"application/json"}]},
        [],
        body_format: :binary
      )

    JSON.decode!(body)
  end

  defp take!(queue, count) do
    start_supervised!(
      {Zizq.Stream.Take, client: :ack, owner: self(), prefetch: count, queues: [queue]},
      id: {:stream, System.unique_integer([:positive])}
    )

    assert_receive {:zizq_stream, _, {:connected, _}}, 5_000

    for _ <- 1..count do
      assert_receive {:zizq_stream, _, {:job, job}}, 5_000
      job
    end
  end

  test "a taken job can be completed", ctx do
    enqueue_retained!(ctx)
    [job] = take!(ctx.queue, 1)

    assert job.status == :in_flight
    assert Zizq.report_success(job, :ack) == :ok

    assert fetch_job!(ctx.url, job.id)["status"] == "completed"
  end

  test "many jobs are completed in one request", ctx do
    for n <- 1..5, do: enqueue_retained!(ctx, payload: %{"n" => n})

    jobs = take!(ctx.queue, 5)

    assert Zizq.report_success_all(jobs, :ack) == {:ok, []}

    for job <- jobs do
      assert fetch_job!(ctx.url, job.id)["status"] == "completed"
    end
  end

  # The partial-success path, produced for real rather than stubbed:
  # one id is genuinely in flight, the other has never existed.
  test "a bulk acknowledge reports ids the server does not hold", ctx do
    enqueue_retained!(ctx)
    [job] = take!(ctx.queue, 1)

    assert {:ok, not_found} = Zizq.report_success_all([job.id, "nonexistent-id"], :ack)
    assert not_found == ["nonexistent-id"]

    # The real one still completed — that is what makes 422 a partial
    # success rather than a failure.
    assert fetch_job!(ctx.url, job.id)["status"] == "completed"
  end

  test "acknowledging twice reports the second as not found", ctx do
    Zizq.enqueue!([type: "probe", queue: ctx.queue], :ack)
    [job] = take!(ctx.queue, 1)

    assert Zizq.report_success(job, :ack) == :ok
    assert {:error, %Zizq.Error{reason: :not_found}} = Zizq.report_success(job, :ack)
  end

  describe "report_failure/3" do
    test "reschedules the job for another attempt", ctx do
      Zizq.enqueue!([type: "probe", queue: ctx.queue, retry_limit: 5], :ack)
      [job] = take!(ctx.queue, 1)

      assert {:ok, failed} = Zizq.report_failure(job, :ack, message: "SMTP timeout")

      assert failed.attempts == 1
      assert failed.status == :scheduled
      # Backoff pushes it into the future rather than making it ready.
      assert DateTime.compare(failed.ready_at, DateTime.utc_now()) == :gt
    end

    test "records the error detail", ctx do
      Zizq.enqueue!([type: "probe", queue: ctx.queue], :ack)
      [job] = take!(ctx.queue, 1)

      assert {:ok, _} =
               Zizq.report_failure(job, :ack,
                 message: "boom",
                 error_type: "RuntimeError",
                 backtrace: "line one\nline two"
               )

      {:ok, {{_, 200, _}, _, body}} =
        :httpc.request(
          :get,
          {~c"#{ctx.url}/jobs/#{job.id}/errors", [{~c"accept", ~c"application/json"}]},
          [],
          body_format: :binary
        )

      assert [error | _] = JSON.decode!(body)["errors"]
      assert error["message"] == "boom"
      assert error["error_type"] == "RuntimeError"
      assert error["backtrace"] == "line one\nline two"
    end

    # What a handler's {:cancel, reason} maps onto.
    test "kill declares the job dead regardless of attempts left", ctx do
      Zizq.enqueue!([type: "probe", queue: ctx.queue, retry_limit: 25], :ack)
      [job] = take!(ctx.queue, 1)

      assert {:ok, killed} = Zizq.report_failure(job, :ack, message: "gone", kill: true)

      assert killed.status == :dead
    end

    # What a handler's {:snooze, seconds} maps onto.
    test "retry_at overrides the backoff schedule", ctx do
      Zizq.enqueue!([type: "probe", queue: ctx.queue], :ack)
      [job] = take!(ctx.queue, 1)

      at = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert {:ok, snoozed} = Zizq.report_failure(job, :ack, message: "later", retry_at: at)

      assert snoozed.status == :scheduled

      assert DateTime.to_unix(snoozed.ready_at, :millisecond) ==
               DateTime.to_unix(at, :millisecond)
    end

    test "an unknown job is reported as not found" do
      assert {:error, %Zizq.Error{reason: :not_found}} =
               Zizq.report_failure("nonexistent-id", :ack, message: "x")
    end
  end
end
