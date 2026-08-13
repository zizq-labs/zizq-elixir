# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Integration.ErrorsTest do
  @moduledoc """
  A job's failure history, recorded by a real server.

  Every record here was written by reporting a genuine failure, so
  what comes back is what a worker actually stored rather than a
  fixture shaped like it.
  """

  use ExUnit.Case, async: false

  setup do
    url = System.fetch_env!("ZIZQ_URL")
    start_supervised!({Zizq, name: :errs, url: url})

    %{url: url, queue: "errs_#{System.unique_integer([:positive])}"}
  end

  defp enqueue!(ctx, opts \\ []) do
    opts
    |> Keyword.merge(type: "errs", queue: ctx.queue)
    |> Keyword.put_new(:retry_limit, 25)
    |> Keyword.put_new(:retention, completed: :timer.minutes(5), dead: :timer.minutes(5))
    |> Zizq.enqueue!(:errs)
  end

  # Takes the job and reports a failure, so the server records one
  # error the way a worker would.
  defp fail!(ctx, opts) do
    start_supervised!(
      {Zizq.Stream.Take, client: :errs, owner: self(), prefetch: 1, queues: [ctx.queue]},
      id: {:stream, System.unique_integer([:positive])}
    )

    assert_receive {:zizq_stream, _, {:connected, _}}, 5_000
    assert_receive {:zizq_stream, _, {:job, taken}}, 5_000

    {:ok, _} = Zizq.report_failure(taken, :errs, opts)
    taken
  end

  test "records what the worker reported", ctx do
    enqueue!(ctx)

    job =
      fail!(ctx,
        message: "SMTP timeout",
        error_type: "Mint.TransportError",
        backtrace: "line one\nline two"
      )

    assert %Zizq.ErrorPage{errors: [error]} = Zizq.list_errors!(job, :errs)

    assert error.attempt == 1
    assert error.message == "SMTP timeout"
    assert error.error_type == "Mint.TransportError"
    assert error.backtrace == "line one\nline two"
  end

  test "a failure without the optional fields still records", ctx do
    enqueue!(ctx)
    job = fail!(ctx, message: "just a message")

    assert %Zizq.ErrorPage{errors: [error]} = Zizq.list_errors!(job, :errs)

    assert error.message == "just a message"
    assert error.error_type == nil
    assert error.backtrace == nil
  end

  test "timestamps come back as DateTimes that bracket the attempt", ctx do
    before = DateTime.utc_now()
    enqueue!(ctx)
    job = fail!(ctx, message: "boom")

    assert %{errors: [error]} = Zizq.list_errors!(job, :errs)

    assert %DateTime{} = error.dequeued_at
    assert %DateTime{} = error.failed_at
    assert DateTime.compare(error.dequeued_at, before) in [:gt, :eq]
    assert DateTime.compare(error.failed_at, error.dequeued_at) in [:gt, :eq]
    assert Zizq.ErrorRecord.duration(error) >= 0
  end

  test "one record per failed attempt, numbered from one", ctx do
    enqueue!(ctx, backoff: [base: 0, exponent: 0.0, jitter: 0])

    job = fail!(ctx, message: "first")
    _ = fail!(ctx, message: "second")

    assert %{errors: errors} = Zizq.list_errors!(job, :errs)

    assert Enum.map(errors, & &1.attempt) == [1, 2]
    assert Enum.map(errors, & &1.message) == ["first", "second"]
  end

  test "get_error reads one attempt", ctx do
    enqueue!(ctx, backoff: [base: 0, exponent: 0.0, jitter: 0])

    job = fail!(ctx, message: "first")
    _ = fail!(ctx, message: "second")

    assert Zizq.get_error!(job, 1, :errs).message == "first"
    assert Zizq.get_error!(job, 2, :errs).message == "second"
  end

  test "an attempt that never failed is :not_found", ctx do
    enqueue!(ctx)
    job = fail!(ctx, message: "only one")

    assert {:error, %Zizq.Error{reason: :not_found}} = Zizq.get_error(job, 2, :errs)
  end

  test "a job that never failed has no errors", ctx do
    job = enqueue!(ctx)

    assert %Zizq.ErrorPage{errors: []} = Zizq.list_errors!(job, :errs)
  end

  test "order reverses the history", ctx do
    enqueue!(ctx, backoff: [base: 0, exponent: 0.0, jitter: 0])

    job = fail!(ctx, message: "first")
    _ = fail!(ctx, message: "second")

    assert Enum.map(Zizq.list_errors!(job, :errs, order: :desc).errors, & &1.message) ==
             ["second", "first"]
  end

  test "paging walks the history", ctx do
    enqueue!(ctx, backoff: [base: 0, exponent: 0.0, jitter: 0])

    job = fail!(ctx, message: "first")
    _ = fail!(ctx, message: "second")
    _ = fail!(ctx, message: "third")

    first = Zizq.list_errors!(job, :errs, limit: 2)
    assert length(first.errors) == 2

    {:ok, second} = Zizq.next_page(first, :errs)
    assert %Zizq.ErrorPage{errors: [%Zizq.ErrorRecord{}]} = second

    walked = Enum.map(first.errors ++ second.errors, & &1.attempt)
    assert walked == [1, 2, 3]
  end
end
