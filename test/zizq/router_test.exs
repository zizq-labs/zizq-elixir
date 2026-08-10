# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.RouterTest do
  @moduledoc """
  Dispatch by job type: what routes where, what a repeated type means,
  and what happens to a type nothing claims.
  """

  use ExUnit.Case, async: true

  alias Zizq.Router
  alias Zizq.Router.UnknownJobType

  defmodule SendEmail do
    use Zizq.JobKind, type: "send_email"

    @impl Zizq.JobKind
    def perform(payload), do: {:email, payload}
  end

  defmodule GenerateReport do
    use Zizq.JobKind, type: "generate_report"

    @impl Zizq.JobKind
    def perform(payload, job), do: {:report, payload, job.id}
  end

  defmodule AlsoSendEmail do
    use Zizq.JobKind, type: "send_email"

    @impl Zizq.JobKind
    def perform(_payload), do: :ok
  end

  defmodule NotAJobKind do
    def type, do: "impostor"
  end

  defp job(type, payload \\ %{}, id \\ "j1") do
    %Zizq.Job{id: id, type: type, queue: "default", payload: payload}
  end

  defp handler(router), do: Router.build(router)

  describe "dispatch" do
    test "routes to the module claiming that type" do
      handler = handler(Router.new([SendEmail, GenerateReport]))

      assert handler.(job("send_email", %{"to" => "a@b.c"})) == {:email, %{"to" => "a@b.c"}}
    end

    test "a perform/2 job receives the job as well as the payload" do
      handler = handler(Router.new([SendEmail, GenerateReport]))

      assert handler.(job("generate_report", %{"id" => 7}, "j9")) ==
               {:report, %{"id" => 7}, "j9"}
    end

    test "a plain function taking only the payload" do
      handler = handler(Router.new([{"ping", fn payload -> {:ping, payload} end}]))

      assert handler.(job("ping", %{"n" => 1})) == {:ping, %{"n" => 1}}
    end

    test "a plain function taking the payload and the job" do
      handler = handler(Router.new([{"audit", fn payload, job -> {:audit, payload, job.id} end}]))

      assert handler.(job("audit", %{"n" => 1}, "j4")) == {:audit, %{"n" => 1}, "j4"}
    end

    test "modules and functions mix freely" do
      handler = handler(Router.new([SendEmail, {"ping", fn _ -> :pong end}]))

      assert handler.(job("ping")) == :pong
      assert handler.(job("send_email", %{})) == {:email, %{}}
    end
  end

  describe "building a route at a time" do
    test "route/2 registers a module under its own type" do
      handler =
        Router.new()
        |> Router.route(SendEmail)
        |> handler()

      assert handler.(job("send_email", %{})) == {:email, %{}}
    end

    test "route/3 registers a function under a type" do
      handler =
        Router.new()
        |> Router.route("ping", fn _payload -> :pong end)
        |> Router.route("audit", fn _payload, job -> {:audit, job.id} end)
        |> handler()

      assert handler.(job("ping")) == :pong
      assert handler.(job("audit", %{}, "j2")) == {:audit, "j2"}
    end

    test "a pipeline adds to a router built from a list" do
      handler =
        Router.new([SendEmail])
        |> Router.route("ping", fn _ -> :pong end)
        |> handler()

      assert handler.(job("send_email", %{})) == {:email, %{}}
      assert handler.(job("ping")) == :pong
    end

    # The point of building one route at a time: start from a router of
    # shared defaults and override a route on top of it.
    test "route/3 replaces an existing route rather than raising" do
      handler =
        Router.new([SendEmail])
        |> Router.route("send_email", fn _ -> :replaced end)
        |> handler()

      assert handler.(job("send_email", %{})) == :replaced
    end

    test "route/2 replaces too" do
      handler =
        Router.new([{"send_email", fn _ -> :original end}])
        |> Router.route(SendEmail)
        |> handler()

      assert handler.(job("send_email", %{})) == {:email, %{}}
    end

    test "fallback/2 replaces an existing fallback" do
      handler =
        Router.new([SendEmail])
        |> Router.fallback(fn _ -> :first end)
        |> Router.fallback(fn _ -> :second end)
        |> handler()

      assert handler.(job("nope")) == :second
    end

    test "building leaves the router it was built from alone" do
      base = Router.new([SendEmail])
      _derived = Router.route(base, "send_email", fn _ -> :replaced end)

      assert handler(base).(job("send_email", %{})) == {:email, %{}}
    end
  end

  describe "unrecognised types" do
    # Raising rather than completing: the worker's crash path turns it
    # into a failure, so the job retries and a rolling deploy that
    # enqueued it from newer code gets a second chance on a worker that
    # knows the type.
    test "raise, naming the type" do
      handler = handler(Router.new([SendEmail]))

      error = assert_raise UnknownJobType, fn -> handler.(job("nope")) end

      assert Exception.message(error) =~ ~s(no handler registered for job type "nope")
      assert error.type == "nope"
    end

    test "go to the fallback when one is given" do
      test_pid = self()
      handler = handler(Router.new([SendEmail], fallback: &send(test_pid, {:fell_back, &1})))

      handler.(job("nope", %{"a" => 1}, "j7"))

      # The whole job, not just the payload — a payload alone says
      # little about a job you did not expect.
      assert_receive {:fell_back, %Zizq.Job{id: "j7", type: "nope", payload: %{"a" => 1}}}
    end

    test "a known type still routes past the fallback" do
      handler = handler(Router.new([SendEmail], fallback: fn _ -> :fallback end))

      assert handler.(job("send_email", %{})) == {:email, %{}}
    end

    # A fallback takes what a handler takes, so a router can defer to
    # another router wholesale.
    test "one router can fall back to another" do
      general = Router.new([{"ping", fn _ -> :pong end}])

      handler =
        Router.new([SendEmail])
        |> Router.fallback(Router.build(general))
        |> handler()

      assert handler.(job("send_email", %{})) == {:email, %{}}
      assert handler.(job("ping")) == :pong
      assert_raise UnknownJobType, fn -> handler.(job("neither")) end
    end

    test "a fallback of the wrong arity is rejected when registered" do
      assert_raise ArgumentError, ~r/taking one argument/, fn ->
        Router.new([SendEmail], fallback: fn _payload, _job -> :ok end)
      end

      # Applied dynamically because the spec already rules this out
      # statically, and a direct call would be a compile-time type
      # warning about the very input under test.
      assert_raise ArgumentError, ~r/taking one argument/, fn ->
        apply(Router, :fallback, [Router.new(), fn _payload, _job -> :ok end])
      end
    end
  end

  describe "registration" do
    # Silently keeping one of them would route half the jobs to a
    # handler nobody chose. Unlike route/3, a list is a single
    # declaration, so a repeat in it is a mistake rather than an
    # override.
    test "two modules in one list claiming the same type is an error" do
      assert_raise ArgumentError, ~r/more than one handler.*"send_email"/, fn ->
        Router.new([SendEmail, AlsoSendEmail])
      end
    end

    test "a module and a function in one list claiming the same type is an error" do
      assert_raise ArgumentError, ~r/more than one handler/, fn ->
        Router.new([SendEmail, {"send_email", fn _ -> :ok end}])
      end
    end

    test "a module that does not use Zizq.JobKind is rejected" do
      assert_raise ArgumentError, ~r/does not.*use Zizq.JobKind/s, fn ->
        Router.new([NotAJobKind])
      end

      assert_raise ArgumentError, ~r/does not.*use Zizq.JobKind/s, fn ->
        Router.route(Router.new(), NotAJobKind)
      end
    end

    test "a function of the wrong arity is rejected" do
      assert_raise ArgumentError, ~r/must take either the payload/, fn ->
        Router.new([{"x", fn _a, _b, _c -> :ok end}])
      end

      assert_raise ArgumentError, ~r/must take either the payload/, fn ->
        Router.route(Router.new(), "x", fn _a, _b, _c -> :ok end)
      end
    end

    test "something that is neither is rejected" do
      assert_raise ArgumentError, ~r/expected a module using Zizq.JobKind/, fn ->
        Router.new(["send_email"])
      end
    end

    # Built when registered rather than per job, so a missing module is
    # a boot failure and not a surprise on the first job of that type.
    test "an unloadable module is rejected when registered" do
      assert_raise ArgumentError, fn -> Router.new([DefinitelyNotAModule]) end
    end
  end
end
