# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Integration.RouterJobs do
  @moduledoc """
  Job kinds for the router integration test.

  Defined at the top level because `use Zizq.JobKind` runs at compile
  time and the modules must exist before the test does. They report
  back to a registered name rather than a captured pid for the same
  reason: a module cannot close over the process that runs the test.
  """

  defmodule Echo do
    use Zizq.JobKind, type: "router_echo", retry_limit: 1

    @impl Zizq.JobKind
    def perform(payload) do
      send(:router_integration, {:echo, payload})
      :ok
    end
  end

  defmodule Inspected do
    use Zizq.JobKind, type: "router_inspected", retry_limit: 1

    @impl Zizq.JobKind
    def perform(payload, job) do
      send(:router_integration, {:inspected, payload, job.id, job.attempts, job.queue})
      :ok
    end
  end
end

defmodule Zizq.Integration.RouterTest do
  @moduledoc """
  `use Zizq.JobKind` and `Zizq.Router` against a real server: an
  enqueue built from a module, taken by a worker, and routed back to
  the module that defined it.
  """

  use ExUnit.Case, async: false

  alias Zizq.Integration.RouterJobs.Echo
  alias Zizq.Integration.RouterJobs.Inspected

  @moduletag capture_log: true

  setup do
    url = System.fetch_env!("ZIZQ_URL")
    start_supervised!({Zizq, name: :rt, url: url})
    Process.register(self(), :router_integration)

    %{url: url, queue: "rt_#{System.unique_integer([:positive])}"}
  end

  defp start_worker!(ctx, handler) do
    start_supervised!(
      {Zizq.Worker,
       client: :rt,
       handler: handler,
       queues: [ctx.queue],
       name: :"rt_#{System.unique_integer([:positive])}",
       drain_timeout: 2_000}
    )
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

  test "a job built from a module routes back to it", ctx do
    Echo.new(%{"greeting" => "hello"}, queue: ctx.queue)
    |> Zizq.enqueue!(:rt)

    start_worker!(ctx, Zizq.Router.new([Echo, Inspected]))

    assert_receive {:echo, %{"greeting" => "hello"}}, 10_000
  end

  test "two kinds on one queue each reach their own module", ctx do
    [
      Echo.new(%{"greeting" => "hi"}, queue: ctx.queue),
      Inspected.new(%{"n" => 1}, queue: ctx.queue)
    ]
    |> Zizq.enqueue_all!(:rt)

    start_worker!(ctx, Zizq.Router.new([Echo, Inspected]))

    assert_receive {:echo, %{"greeting" => "hi"}}, 10_000
    assert_receive {:inspected, %{"n" => 1}, _id, _attempts, _queue}, 10_000
  end

  test "perform/2 receives the job the server actually sent", ctx do
    job = Zizq.enqueue!(Inspected.new(%{"n" => 2}, queue: ctx.queue), :rt)

    start_worker!(ctx, Zizq.Router.new([Inspected]))

    assert_receive {:inspected, %{"n" => 2}, id, attempts, queue}, 10_000

    assert id == job.id
    assert queue == ctx.queue
    # Counted by the server, so this is the round trip and not a value
    # the client made up. Zero on a first delivery: `attempts` counts
    # attempts already finished, and this one is still running — which
    # is what makes `when attempts >= 3` in a handler mean "has failed
    # three times already".
    assert attempts == 0
  end

  # The type reaches the worker as data from the queue; nothing on the
  # client resolves it to code. An unrouted one has to fail loudly.
  test "an unrouted type fails the job, naming itself", ctx do
    job =
      Zizq.enqueue!(
        [type: "router_unrouted", queue: ctx.queue, retry_limit: 2],
        :rt
      )

    start_worker!(ctx, Zizq.Router.new([Echo]))

    eventually(fn -> Zizq.get_job!(job.id, :rt).attempts == 1 end)

    {:ok, {{_, 200, _}, _, body}} =
      :httpc.request(
        :get,
        {~c"#{ctx.url}/jobs/#{job.id}/errors", [{~c"accept", ~c"application/json"}]},
        [],
        body_format: :binary
      )

    assert [error | _] = JSON.decode!(body)["errors"]
    assert error["error_type"] == "Zizq.Router.UnknownJobType"
    assert error["message"] =~ ~s(no handler registered for job type "router_unrouted")
  end

  test "a fallback handles the unrouted type instead of failing it", ctx do
    test_pid = self()

    Zizq.enqueue!([type: "router_unrouted", queue: ctx.queue], :rt)

    # Built a route at a time, so the end-to-end path covers the
    # pipeline form as well as the list form the other tests use.
    handler =
      Zizq.Router.new()
      |> Zizq.Router.route(Echo)
      |> Zizq.Router.fallback(fn job ->
        send(test_pid, {:fell_back, job.type})
        :ok
      end)

    start_worker!(ctx, handler)

    assert_receive {:fell_back, "router_unrouted"}, 10_000
  end
end
