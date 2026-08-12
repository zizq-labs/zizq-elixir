# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Integration.JobCrudTest do
  @moduledoc """
  Reading, changing and deleting one job against a real server.

  The unit tests pin what the client *sends*; only a real server says
  whether it means what we think. Two things in particular can only be
  checked here: that the wire field names are the ones the server
  reads — a fake server echoes whatever it is given — and that a patch
  body survives MessagePack, which is the client's default format and
  the one this suite runs.
  """

  use ExUnit.Case, async: false

  setup do
    url = System.fetch_env!("ZIZQ_URL")
    start_supervised!({Zizq, name: :crud, url: url})

    %{url: url, queue: "crud_#{System.unique_integer([:positive])}"}
  end

  defp enqueue!(ctx, opts \\ []) do
    opts
    |> Keyword.merge(type: "crud", queue: ctx.queue)
    |> Keyword.put_new(:retention, completed: :timer.minutes(5), dead: :timer.minutes(5))
    |> Zizq.enqueue!(:crud)
  end

  describe "get_job/2" do
    test "returns the job the server holds, payload included", ctx do
      job = enqueue!(ctx, payload: %{"user_id" => 42, "nested" => %{"a" => [1, 2]}})

      fetched = Zizq.get_job!(job.id, :crud)

      assert fetched.id == job.id
      assert fetched.type == "crud"
      assert fetched.queue == ctx.queue
      assert fetched.status == :ready
      # Round-tripped through MessagePack in both directions.
      assert fetched.payload == %{"user_id" => 42, "nested" => %{"a" => [1, 2]}}
    end

    test "a job that never existed is :not_found", _ctx do
      assert {:error, %Zizq.Error{reason: :not_found}} =
               Zizq.get_job("01ARZ3NDEKTSV4RRFFQ69G5FAV", :crud)
    end
  end

  describe "update_job/3" do
    test "moves a job and changes its priority", ctx do
      job = enqueue!(ctx, priority: 100)

      updated = Zizq.update_job!(job, :crud, queue: "#{ctx.queue}_moved", priority: 5)

      assert updated.queue == "#{ctx.queue}_moved"
      assert updated.priority == 5
      # Not just the response: the change is what the server stored.
      assert Zizq.get_job!(job.id, :crud).queue == "#{ctx.queue}_moved"
    end

    # The half of merge patch that is easy to get wrong in the other
    # direction: naming one field must not reset the others.
    test "an omitted field is left exactly as it was", ctx do
      job = enqueue!(ctx, priority: 100, retry_limit: 9)

      updated = Zizq.update_job!(job, :crud, priority: 5)

      assert updated.priority == 5
      assert updated.retry_limit == 9
    end

    # And the half that only a real server can confirm: `nil` has to
    # reach it as a JSON null, not be dropped on the way — dropping it
    # would leave the override in place and pass a fake server.
    #
    # Compared against a job that never set the field rather than
    # against a literal, so this says "back to whatever unset means"
    # without encoding the server's default here.
    test "nil clears a field back to the server's default", ctx do
      untouched = Zizq.get_job!(enqueue!(ctx).id, :crud)
      job = enqueue!(ctx, retry_limit: 99)

      assert Zizq.get_job!(job.id, :crud).retry_limit == 99
      refute untouched.retry_limit == 99

      updated = Zizq.update_job!(job, :crud, retry_limit: nil)

      assert updated.retry_limit == untouched.retry_limit
    end

    test "ready_at defers the job", ctx do
      job = enqueue!(ctx)
      at = DateTime.add(DateTime.utc_now(), 3_600, :second)

      updated = Zizq.update_job!(job, :crud, ready_at: at)

      assert updated.status == :scheduled

      assert DateTime.to_unix(updated.ready_at, :millisecond) ==
               DateTime.to_unix(at, :millisecond)
    end

    test "backoff and retention round-trip under their wire names", ctx do
      job = enqueue!(ctx)

      updated =
        Zizq.update_job!(job, :crud,
          backoff: [base: :timer.seconds(15), exponent: 3.0, jitter: :timer.seconds(30)],
          retention: [completed: :timer.hours(2), dead: :timer.hours(3)]
        )

      assert %Zizq.Backoff{base: 15_000, exponent: 3.0, jitter: 30_000} = updated.backoff
      assert %Zizq.Retention{completed: 7_200_000, dead: 10_800_000} = updated.retention
    end

    # Retention merge-patches its sub-fields, so naming one leaves the
    # other alone — a nested merge the client never has to know about
    # beyond omitting the key.
    test "a retention patch leaves the sub-field it does not name", ctx do
      job = enqueue!(ctx, retention: [completed: :timer.hours(1), dead: :timer.hours(4)])

      updated = Zizq.update_job!(job, :crud, retention: [completed: :timer.hours(2)])

      assert updated.retention.completed == 7_200_000
      assert updated.retention.dead == 14_400_000
    end

    test "a finished job cannot be changed", ctx do
      job = enqueue!(ctx)
      complete!(ctx, job)

      assert {:error, %Zizq.Error{reason: reason}} = Zizq.update_job(job, :crud, priority: 1)
      assert reason in [:invalid_request, :conflict]
    end

    test "a job that never existed is :not_found", _ctx do
      assert {:error, %Zizq.Error{reason: :not_found}} =
               Zizq.update_job("01ARZ3NDEKTSV4RRFFQ69G5FAV", :crud, priority: 1)
    end
  end

  describe "delete_job/2" do
    test "removes the job outright", ctx do
      job = enqueue!(ctx)

      assert Zizq.delete_job(job, :crud) == :ok
      assert {:error, %Zizq.Error{reason: :not_found}} = Zizq.get_job(job.id, :crud)
    end

    # Unlike `report_failure/3` with `kill: true`, which leaves a dead
    # job behind to be looked at.
    test "deleting twice is :not_found the second time", ctx do
      job = enqueue!(ctx)

      assert Zizq.delete_job(job, :crud) == :ok
      assert {:error, %Zizq.Error{reason: :not_found}} = Zizq.delete_job(job, :crud)
    end

    test "a job that never existed is :not_found", _ctx do
      assert {:error, %Zizq.Error{reason: :not_found}} =
               Zizq.delete_job("01ARZ3NDEKTSV4RRFFQ69G5FAV", :crud)
    end
  end

  # Takes the job and acknowledges it, so the server records it as
  # finished. Retention keeps it readable afterwards.
  defp complete!(ctx, job) do
    start_supervised!(
      {Zizq.Stream.Take, client: :crud, owner: self(), prefetch: 1, queues: [ctx.queue]},
      id: {:stream, System.unique_integer([:positive])}
    )

    assert_receive {:zizq_stream, _, {:connected, _}}, 5_000
    assert_receive {:zizq_stream, _, {:job, taken}}, 5_000
    assert taken.id == job.id

    :ok = Zizq.report_success(taken, :crud)

    eventually(fn -> Zizq.get_job!(job.id, :crud).status == :completed end)
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
end
