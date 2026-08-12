# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.TestingTest do
  @moduledoc """
  The test helpers, tested through the same door a user goes in by —
  `use Zizq.Testing` with a fixed client name, under `async: true`,
  since that combination is what has to work.
  """

  use ExUnit.Case, async: true
  use Zizq.Testing, client: MyApp.Zizq

  defmodule SendEmail do
    use Zizq.JobKind, type: "send_email", queue: "emails"

    # Wrapped in `{:ok, _}` because a handler has to return a
    # recognised outcome — which `perform_job/3` now enforces.
    @impl Zizq.JobKind
    def perform(%{"user_id" => id}), do: {:ok, {:sent, id}}
  end

  defmodule WithJob do
    use Zizq.JobKind, type: "with_job"

    @impl Zizq.JobKind
    def perform(payload, job), do: {:ok, {:ran, payload, job.id, job.attempts, job.queue}}
  end

  defmodule NotAJobKind do
    def hello, do: :world
  end

  describe "recording enqueues" do
    test "an enqueue is recorded rather than sent" do
      assert {:ok, %Zizq.Job{}} = Zizq.enqueue([type: "send_email"], MyApp.Zizq)

      assert_enqueued(type: "send_email")
    end

    test "the job comes back as the server would return it" do
      {:ok, job} = Zizq.enqueue([type: "send_email", queue: "emails"], MyApp.Zizq)

      assert job.id
      assert job.type == "send_email"
      assert job.queue == "emails"
      assert job.status == :ready
      assert job.attempts == 0
    end

    test "a bulk enqueue records every job" do
      {:ok, jobs} =
        Zizq.enqueue_all([[type: "a"], [type: "b"]], MyApp.Zizq)

      assert length(jobs) == 2
      assert_enqueued(type: "a")
      assert_enqueued(type: "b")
    end

    test "jobs built from a module record their module's defaults" do
      SendEmail.new(%{"user_id" => 42}) |> Zizq.enqueue!(MyApp.Zizq)

      assert_enqueued(type: "send_email", queue: "emails")
    end

    # Everything above the request still runs, so a typo is caught in a
    # test exactly as it would be in production.
    test "validation still applies" do
      assert_raise ArgumentError, ~r/unknown enqueue key/, fn ->
        Zizq.enqueue([type: "a", payloads: %{}], MyApp.Zizq)
      end
    end

    # The recorder sits below key derivation, so what is recorded is
    # what would have gone over the wire.
    test "derived unique keys are recorded, already resolved" do
      Zizq.enqueue(
        [type: "a", payload: %{"user_id" => 7}, unique_key: {:payload, only: [".user_id"]}],
        MyApp.Zizq
      )

      assert [job] = all_enqueued()
      assert "a:" <> digest = job["unique_key"]
      assert String.length(digest) == 64
    end

    # The server stores what JSON round-tripping produces, so an
    # assertion written against string keys has to match code that
    # enqueued atom keys.
    test "an atom-keyed payload is recorded string-keyed" do
      Zizq.enqueue([type: "a", payload: %{user_id: 42}], MyApp.Zizq)

      assert_enqueued(payload: %{"user_id" => 42})
      assert [%{"payload" => %{"user_id" => 42}}] = all_enqueued()
    end

    test "endpoints other than enqueuing say so plainly" do
      assert_raise ArgumentError, ~r/not supported by Zizq.Testing/, fn ->
        Zizq.report_success("some-id", MyApp.Zizq)
      end
    end
  end

  describe "assert_enqueued/1 and refute_enqueued/1" do
    test "match on any subset of the fields" do
      Zizq.enqueue([type: "send_email", queue: "emails", payload: %{"a" => 1}], MyApp.Zizq)

      assert_enqueued(type: "send_email")
      assert_enqueued(queue: "emails")
      assert_enqueued(type: "send_email", queue: "emails")
    end

    # A test names the payload keys it cares about; the rest of the
    # payload should not have to be restated.
    test "a payload matches on the keys given, ignoring the others" do
      Zizq.enqueue([type: "a", payload: %{"user_id" => 42, "noise" => "x"}], MyApp.Zizq)

      assert_enqueued(payload: %{"user_id" => 42})
      refute_enqueued(payload: %{"user_id" => 43})
    end

    test "every field given must match, not just one" do
      Zizq.enqueue([type: "send_email", queue: "emails"], MyApp.Zizq)

      refute_enqueued(type: "send_email", queue: "other")
    end

    test "refute passes when nothing was enqueued at all" do
      refute_enqueued(type: "send_email")
    end

    test "a failed assertion lists what was enqueued" do
      Zizq.enqueue([type: "actually_this"], MyApp.Zizq)

      error =
        assert_raise ExUnit.AssertionError, fn -> assert_enqueued(type: "expected_this") end

      assert error.message =~ "expected_this"
      assert error.message =~ "actually_this"
    end

    test "a failed refutation shows what matched" do
      Zizq.enqueue([type: "send_email"], MyApp.Zizq)

      error =
        assert_raise ExUnit.AssertionError, fn -> refute_enqueued(type: "send_email") end

      assert error.message =~ "1 matched"
    end

    test "all_enqueued/1 returns them in the order they were made" do
      Zizq.enqueue([type: "first"], MyApp.Zizq)
      Zizq.enqueue([type: "second"], MyApp.Zizq)

      assert ["first", "second"] = Enum.map(all_enqueued(), & &1["type"])
    end
  end

  describe "isolation" do
    # The property that makes a fixed client name safe under async:
    # recordings belong to the test, not to the client.
    test "one test does not see another's enqueues (a)" do
      Zizq.enqueue([type: "from_a"], MyApp.Zizq)

      assert ["from_a"] = Enum.map(all_enqueued(), & &1["type"])
    end

    test "one test does not see another's enqueues (b)" do
      Zizq.enqueue([type: "from_b"], MyApp.Zizq)

      assert ["from_b"] = Enum.map(all_enqueued(), & &1["type"])
    end

    # Code under test often enqueues from a Task; `$callers` is what
    # attributes it back to the test that started it.
    test "an enqueue from a Task is attributed to the test" do
      Task.async(fn -> Zizq.enqueue([type: "from_task"], MyApp.Zizq) end)
      |> Task.await()

      assert_enqueued(type: "from_task")
    end

    test "an enqueue from a nested Task is attributed too" do
      Task.async(fn ->
        Task.async(fn -> Zizq.enqueue([type: "from_nested"], MyApp.Zizq) end)
        |> Task.await()
      end)
      |> Task.await()

      assert_enqueued(type: "from_nested")
    end
  end

  describe "drain_enqueued/2" do
    defmodule Chain do
      use Zizq.JobKind, type: "chain"

      # Enqueues a successor until the countdown runs out, which is
      # what `:recursive` exists for.
      @impl Zizq.JobKind
      def perform(%{"n" => n}) do
        if n > 0, do: Zizq.enqueue!(Chain.new(%{"n" => n - 1}), MyApp.Zizq)
        :ok
      end
    end

    defmodule Forever do
      use Zizq.JobKind, type: "forever"

      @impl Zizq.JobKind
      def perform(_payload) do
        Zizq.enqueue!(Forever.new(%{}), MyApp.Zizq)
        :ok
      end
    end

    defp collector(test_pid) do
      fn job ->
        send(test_pid, {:ran, job.type, job.payload})
        :ok
      end
    end

    test "runs each enqueued job and counts them" do
      Zizq.enqueue!([type: "a"], MyApp.Zizq)
      Zizq.enqueue!([type: "b"], MyApp.Zizq)

      assert drain_enqueued(collector(self())) == 2
      assert_receive {:ran, "a", _}
      assert_receive {:ran, "b", _}
    end

    test "hands the handler a real job, payload included" do
      Zizq.enqueue!([type: "a", queue: "q", payload: %{"n" => 1}], MyApp.Zizq)

      drain_enqueued(fn job ->
        send(self(), {:seen, job})
        :ok
      end)

      assert_received {:seen, %Zizq.Job{type: "a", queue: "q", payload: %{"n" => 1}}}
    end

    test "a router works as the handler" do
      test_pid = self()

      route = fn payload ->
        send(test_pid, {:routed, payload})
        :ok
      end

      router = Zizq.Router.new([{"a", route}])

      Zizq.enqueue!([type: "a", payload: %{"n" => 1}], MyApp.Zizq)

      assert drain_enqueued(router) == 1
      assert_receive {:routed, %{"n" => 1}}
    end

    test "a job is drained once" do
      Zizq.enqueue!([type: "a"], MyApp.Zizq)

      assert drain_enqueued(collector(self())) == 1
      assert drain_enqueued(collector(self())) == 0
    end

    test "a second call picks up what was enqueued since" do
      Zizq.enqueue!([type: "a"], MyApp.Zizq)
      assert drain_enqueued(collector(self())) == 1

      Zizq.enqueue!([type: "b"], MyApp.Zizq)
      assert drain_enqueued(collector(self())) == 1
    end

    test "filters restrict what is drained" do
      Zizq.enqueue!([type: "a", queue: "keep"], MyApp.Zizq)
      Zizq.enqueue!([type: "b", queue: "skip"], MyApp.Zizq)

      assert drain_enqueued(collector(self()), queue: "keep") == 1
      assert_receive {:ran, "a", _}
      refute_received {:ran, "b", _}
    end

    test "jobs run in the order they were enqueued" do
      for n <- 1..5, do: Zizq.enqueue!([type: "a", payload: %{"n" => n}], MyApp.Zizq)

      drain_enqueued(collector(self()))

      for n <- 1..5, do: assert_receive({:ran, "a", %{"n" => ^n}})
    end

    # Without `:recursive`, a handler's own enqueues wait for the next
    # call rather than extending the round in progress.
    test "a handler's enqueues are left for the next call by default" do
      Zizq.enqueue!(Chain.new(%{"n" => 2}), MyApp.Zizq)

      assert drain_enqueued(Zizq.Router.new([Chain])) == 1
      assert drain_enqueued(Zizq.Router.new([Chain])) == 1
    end

    test ":recursive keeps going until nothing new is enqueued" do
      Zizq.enqueue!(Chain.new(%{"n" => 3}), MyApp.Zizq)

      assert drain_enqueued(Zizq.Router.new([Chain]), recursive: true) == 4
      assert drain_enqueued(Zizq.Router.new([Chain]), recursive: true) == 0
    end

    # Otherwise a handler that always enqueues hangs the suite.
    test ":recursive gives up rather than looping forever" do
      Zizq.enqueue!(Forever.new(%{}), MyApp.Zizq)

      error =
        assert_raise ExUnit.AssertionError, fn ->
          drain_enqueued(Zizq.Router.new([Forever]), recursive: true, max_iterations: 5)
        end

      assert error.message =~ "max_iterations"
    end

    test "an unrecognised return value fails the test" do
      Zizq.enqueue!([type: "a"], MyApp.Zizq)

      assert_raise ExUnit.AssertionError, ~r/does not recognise/, fn ->
        drain_enqueued(fn _job -> %{rows: 1} end)
      end
    end

    # Marked drained before running, so a retry cannot loop on the job
    # that raised.
    test "a raising handler propagates, and does not run again" do
      Zizq.enqueue!([type: "a"], MyApp.Zizq)

      assert_raise ArgumentError, "boom", fn ->
        drain_enqueued(fn _job -> raise ArgumentError, "boom" end)
      end

      assert drain_enqueued(collector(self())) == 0
    end

    test "draining nothing is fine" do
      assert drain_enqueued(collector(self())) == 0
    end

    test "an unusable handler says so" do
      assert_raise ArgumentError, ~r/one-argument function/, fn ->
        drain_enqueued(:not_a_handler)
      end
    end
  end

  describe "perform_job/3" do
    test "runs a module's handler and returns what it returned" do
      assert perform_job(SendEmail, %{"user_id" => 42}) == {:ok, {:sent, 42}}
    end

    test "a perform/2 handler receives a job" do
      assert {:ok, {:ran, _payload, id, 0, "default"}} = perform_job(WithJob, %{"a" => 1})
      assert is_binary(id)
    end

    test "job fields can be set, for handlers that branch on them" do
      assert {:ok, {:ran, _payload, "j1", 3, "urgent"}} =
               perform_job(WithJob, %{}, id: "j1", attempts: 3, queue: "urgent")
    end

    test "the type defaults to the module's own" do
      router = Zizq.Router.new([SendEmail])

      assert perform_job(router, %{"user_id" => 1}, type: "send_email") == {:ok, {:sent, 1}}
    end

    # Returned rather than acted on: a worker decides what an error
    # means, and there is no worker here.
    test "an error outcome comes back verbatim" do
      defmodule Failing do
        use Zizq.JobKind, type: "failing"

        @impl Zizq.JobKind
        def perform(_payload), do: {:error, "SMTP timeout"}
      end

      assert perform_job(Failing, %{}) == {:error, "SMTP timeout"}
    end

    test "a raising handler raises here too" do
      defmodule Raising do
        use Zizq.JobKind, type: "raising"

        @impl Zizq.JobKind
        def perform(_payload), do: raise(ArgumentError, "boom")
      end

      assert_raise ArgumentError, "boom", fn -> perform_job(Raising, %{}) end
    end

    test "routing needs a type, since that is what a router dispatches on" do
      router = Zizq.Router.new([SendEmail])

      assert_raise ArgumentError, ~r/needs a :type/, fn ->
        perform_job(router, %{"user_id" => 1})
      end
    end

    # Production hands a handler a payload that has been through the
    # wire, so it is always string-keyed. A test passing atom keys
    # would otherwise match a clause that can never match in
    # production, and pass.
    test "an atom-keyed payload reaches the handler string-keyed" do
      assert perform_job(SendEmail, %{user_id: 42}) == {:ok, {:sent, 42}}
    end

    test "nested and non-map payloads normalise too" do
      assert {:ok, {:ran, payload, _, _, _}} =
               perform_job(WithJob, %{outer: %{inner: [1, %{deep: true}]}})

      assert payload == %{"outer" => %{"inner" => [1, %{"deep" => true}]}}
    end

    # The worker accepts these and warns; a test is where catching them
    # is cheapest, so here it fails.
    test "an unrecognised return value fails the test" do
      defmodule Sloppy do
        use Zizq.JobKind, type: "sloppy"

        @impl Zizq.JobKind
        def perform(_payload), do: %{rows: 1}
      end

      error = assert_raise ExUnit.AssertionError, fn -> perform_job(Sloppy, %{}) end

      assert error.message =~ "does not recognise"
      assert error.message =~ "rows"
    end

    # The exact typo the worker's warning exists for.
    test "a misspelled outcome tag fails the test" do
      defmodule Typo do
        use Zizq.JobKind, type: "typo"

        @impl Zizq.JobKind
        def perform(_payload), do: {:eror, "oops"}
      end

      assert_raise ExUnit.AssertionError, ~r/does not recognise/, fn ->
        perform_job(Typo, %{})
      end
    end

    test "every documented outcome is accepted" do
      for {return, label} <- [
            {:ok, ":ok"},
            {{:ok, 1}, "{:ok, value}"},
            {{:error, "x"}, "{:error, reason}"},
            {{:cancel, :gone}, "{:cancel, reason}"},
            {{:snooze, 1_000}, "{:snooze, ms}"}
          ] do
        module = Module.concat(__MODULE__, "Outcome#{System.unique_integer([:positive])}")

        Module.create(
          module,
          quote do
            use Zizq.JobKind, type: "outcome"

            @impl Zizq.JobKind
            def perform(_payload), do: unquote(Macro.escape(return))
          end,
          Macro.Env.location(__ENV__)
        )

        assert perform_job(module, %{}) == return, "expected #{label} to be accepted"
      end
    end

    test "a module that is not a job kind says so" do
      assert_raise ArgumentError, ~r/does not.*use Zizq.JobKind/s, fn ->
        perform_job(NotAJobKind, %{})
      end
    end
  end
end
