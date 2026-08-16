# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Testing do
  @moduledoc """
  Assert on what your code enqueued, and run job handlers directly,
  without a server.

  Start the recorder once, in `test/test_helper.exs`:

      Zizq.Testing.start_link()
      ExUnit.start()

  Then in a case, name the client your code enqueues through:

      defmodule MyApp.SignupTest do
        use ExUnit.Case, async: true
        use Zizq.Testing, client: MyApp.Zizq

        test "signing up sends a welcome email" do
          MyApp.Signup.run("ada@example.com")

          assert_enqueued(type: "send_email", payload: %{"template" => "welcome"})
        end
      end

  `use Zizq.Testing` sets up the client for each test and imports the
  assertions bound to it, so nothing needs passing around.

  ## Enqueues are recorded, not sent

  A client set up this way handles enqueues in memory instead of
  contacting a server, and hands back a `Zizq.Job` as the server would
  — with a synthetic id, `status: :ready`, and `attempts: 0`.
  Everything upstream of the request runs unchanged, so option
  validation, payload-derived unique keys and batch keys, and
  telemetry all behave as they do in production.

  Endpoints other than enqueuing raise: there is no server to have
  taken a job, so acknowledging or streaming one has no meaning here.

  ## Recordings are per test

  Recordings belong to the test process that made them, not to the
  client, so a fixed client name is safe under `async: true`. Enqueues
  from a `Task` or a spawned process count too, as long as the process
  was started from the test — `$callers` is followed to find the
  owner. A process started outside that chain, such as a supervised
  worker, is not attributable and its enqueues are not recorded.

  ## Assertions

  `assert_enqueued/1` and `refute_enqueued/1` take a subset of the
  fields to match on. A job matches when every field given matches:

      assert_enqueued(type: "send_email")
      assert_enqueued(type: "send_email", queue: "emails")
      assert_enqueued(payload: %{"user_id" => 42})

  A `:payload` matches when the recorded payload *contains* what was
  given, so a test names the keys it cares about and ignores the rest.

  `all_enqueued/1` returns the matching enqueues for anything the
  assertions do not cover.

  `clear_enqueued/0` forgets what has been recorded so far, so a test
  that acts twice can assert on the second action alone.

  ## Payloads are what the server would have stored

  A payload is normalised through JSON on the way in, exactly as it is
  on the way to a real server, so a payload enqueued as `%{user_id: 1}`
  records and matches as `%{"user_id" => 1}`. The same applies to a
  payload handed to `perform_job/3`: a handler receives string keys
  here because it receives string keys in production, and a test
  passing atom keys would otherwise match a clause that can never run.
  """

  use GenServer

  alias Zizq.Config

  @table __MODULE__

  @doc false
  defmacro __using__(opts) do
    client = Keyword.fetch!(opts, :client)

    quote do
      import Zizq.Testing,
        only: [
          assert_enqueued: 1,
          refute_enqueued: 1,
          all_enqueued: 0,
          all_enqueued: 1,
          clear_enqueued: 0,
          perform_job: 2,
          perform_job: 3,
          drain_enqueued: 1,
          drain_enqueued: 2
        ]

      setup do
        Zizq.Testing.setup_client(unquote(client))
        :ok
      end
    end
  end

  # --- Recorder ---

  @doc """
  Start the recorder. Call once, from `test/test_helper.exs`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    # Public so enqueues record from whichever process made them, with
    # no round trip through this one. It only owns the table.
    :ets.new(@table, [:named_table, :public, :bag, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Point `client` at the recorder, and own its recordings for this test.

  Called for you by `use Zizq.Testing`. Safe to call from several tests
  at once: the client is shared, the recordings are not.
  """
  @spec setup_client(atom()) :: :ok
  def setup_client(client) when is_atom(client) do
    unless Process.whereis(__MODULE__) do
      raise """
      the Zizq test recorder is not running.

      Add this to test/test_helper.exs, before `ExUnit.start()`:

          Zizq.Testing.start_link()
      """
    end

    Config.put(%Config{
      name: client,
      uri: URI.parse("http://zizq.test"),
      codec: Zizq.Codec.JSON,
      recorder: self()
    })

    owner = self()
    :ets.insert(@table, {{:owner, owner}, true})

    ExUnit.Callbacks.on_exit(fn ->
      :ets.match_delete(@table, {{:owner, owner}, :_})
      :ets.match_delete(@table, {{:enqueue, owner}, :_})
      :ets.match_delete(@table, {{:drained, owner}, :_})
    end)

    :ok
  end

  @doc false
  # The seam `Zizq.HTTP` diverts to. Answers as the server would rather
  # than short-circuiting higher up, so the code under test runs the
  # same path it runs in production.
  @spec record(String.t(), map()) :: {:ok, 201, map()} | no_return()
  def record("/jobs", wire) do
    {:ok, 201, put_recorded(wire)}
  end

  def record("/jobs/bulk", %{"jobs" => jobs}) do
    {:ok, 201, %{"jobs" => Enum.map(jobs, &put_recorded/1)}}
  end

  def record(path, _wire) do
    raise ArgumentError, """
    #{path} is not supported by Zizq.Testing.

    Only enqueuing is recorded. Acknowledging or streaming a job needs
    a server to have delivered one — run those against a real server,
    or call your handler directly with perform_job/2.
    """
  end

  defp put_recorded(wire) do
    wire = Map.update(wire, "payload", nil, &normalise_payload/1)
    job = Map.merge(wire, %{"id" => synthetic_id(), "status" => "ready", "attempts" => 0})

    case owner() do
      nil -> :ok
      owner -> :ets.insert(@table, {{:enqueue, owner}, job})
    end

    job
  end

  # A `Task` started from a test does not own the recording, but the
  # test that started it does. `$callers` is the chain OTP maintains
  # for exactly this.
  defp owner do
    [self() | Process.get(:"$callers", [])]
    |> Enum.find(&:ets.member(@table, {:owner, &1}))
  end

  defp synthetic_id do
    "test_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  # --- Assertions ---

  @doc """
  Every enqueue this test made, most recent last, optionally filtered.
  """
  @spec all_enqueued(keyword()) :: [map()]
  def all_enqueued(filters \\ []) do
    @table
    |> :ets.lookup({:enqueue, owner() || self()})
    |> Enum.map(&elem(&1, 1))
    |> Enum.filter(&matches?(&1, filters))
  end

  @doc """
  Forget everything recorded so far.

  Assertions after this see only what was enqueued from here on, which
  is what a test that acts twice needs: the first action's enqueues
  would otherwise still be sitting there for `refute_enqueued/1` to
  find, and a refutation cannot tell the two apart.

      MyApp.Sitemap.scan(sitemap)
      assert_enqueued(type: "check_url")

      clear_enqueued()

      # The second scan should find nothing new to do.
      MyApp.Sitemap.scan(sitemap)
      refute_enqueued(type: "check_url")

  Only this test's recordings go, so it is safe under `async: true`.

  Drain bookkeeping is dropped alongside them, so "cleared" means
  cleared rather than half-cleared. That has no effect you can
  observe — every enqueue gets a fresh id, so an already-drained one
  could never come up again — it just keeps the two halves of a
  test's state from disagreeing.
  """
  @spec clear_enqueued() :: :ok
  def clear_enqueued do
    owner = owner() || self()

    :ets.match_delete(@table, {{:enqueue, owner}, :_})
    :ets.match_delete(@table, {{:drained, owner}, :_})

    :ok
  end

  @doc """
  Assert that a job matching `filters` was enqueued.
  """
  @spec assert_enqueued(keyword()) :: true
  def assert_enqueued(filters) do
    case all_enqueued(filters) do
      [] -> raise ExUnit.AssertionError, message: failure_message("Expected", filters)
      _matched -> true
    end
  end

  @doc """
  Assert that no job matching `filters` was enqueued.
  """
  @spec refute_enqueued(keyword()) :: true
  def refute_enqueued(filters) do
    case all_enqueued(filters) do
      [] -> true
      matched -> raise ExUnit.AssertionError, message: refutation_message(filters, matched)
    end
  end

  defp matches?(job, filters) do
    Enum.all?(filters, fn {field, expected} -> field_matches?(job, field, expected) end)
  end

  # Containment rather than equality, so a test names the payload keys
  # it cares about without restating the ones it does not.
  defp field_matches?(job, :payload, expected) when is_map(expected) do
    actual = Map.get(job, "payload")

    is_map(actual) and
      Enum.all?(expected, fn {key, value} -> Map.get(actual, to_string(key)) == value end)
  end

  defp field_matches?(job, field, expected), do: Map.get(job, to_string(field)) == expected

  defp failure_message(lead, filters) do
    """
    #{lead} a job matching:

    #{inspect(filters, pretty: true)}

    #{describe_recorded()}
    """
  end

  defp refutation_message(filters, matched) do
    """
    Expected no job matching:

    #{inspect(filters, pretty: true)}

    but #{length(matched)} matched:

    #{inspect(matched, pretty: true)}
    """
  end

  defp describe_recorded do
    case all_enqueued() do
      [] -> "No jobs were enqueued."
      jobs -> "Enqueued jobs were:\n\n#{inspect(jobs, pretty: true)}"
    end
  end

  # --- Running a handler ---

  @doc """
  Run a job's handler directly, without a worker or a server.

  Takes a module using `Zizq.JobKind`, or a `Zizq.Router`:

      assert :ok = perform_job(MyApp.SendEmail, %{"user_id" => 42})
      assert :ok = perform_job(router, %{"user_id" => 42}, type: "send_email")

  Returns whatever the handler returned, verbatim — including
  `{:error, reason}` — so a test asserts on the outcome rather than on
  what a worker would have done with it. Anything the handler raises
  propagates.

  The return value must be one a worker recognises, and the test fails
  if it is not. A worker would acknowledge an unrecognised value as
  complete and log a warning; a test is where that is cheapest to
  catch, so it is an assertion failure here.

  ## Options

    * `:type`, `:queue`, `:id`, `:attempts` — fields of the
      `Zizq.Job` the handler receives. `:attempts` counts attempts
      already finished, so it defaults to `0`.
  """
  @spec perform_job(module() | Zizq.Router.t(), term(), keyword()) :: term()
  def perform_job(module_or_router, payload, opts \\ [])

  def perform_job(%Zizq.Router{} = router, payload, opts) do
    unless Keyword.has_key?(opts, :type) do
      raise ArgumentError,
            "performing a job through a Zizq.Router needs a :type, since that is " <>
              "what the router dispatches on"
    end

    handler = Zizq.Router.build(router)
    perform(fn _payload, job -> handler.(job) end, payload, opts)
  end

  def perform_job(module, payload, opts) when is_atom(module) do
    Code.ensure_loaded!(module)

    unless function_exported?(module, :__zizq_perform__, 2) do
      raise ArgumentError,
            "#{inspect(module)} does not `use Zizq.JobKind`, so it has no handler to " <>
              "perform. Pass a Zizq.Router, or the module that defines the job."
    end

    opts = Keyword.put_new(opts, :type, module.type())
    perform(fn payload, job -> module.__zizq_perform__(payload, job) end, payload, opts)
  end

  defp perform(fun, payload, opts) do
    # A payload reaches a handler having been through the wire, so it
    # is always string-keyed there. Without this a test could pass
    # `%{user_id: 1}`, match a clause production never would, and go
    # green on a handler that cannot run.
    payload = normalise_payload(payload)

    payload
    |> then(&fun.(&1, job(&1, opts)))
    |> tap(&assert_valid_outcome/1)
  end

  # The worker accepts an unrecognised return and warns. A test is
  # where that is cheapest to catch, so here it fails instead.
  defp assert_valid_outcome(result) do
    if Zizq.Worker.Runner.outcome(result) == :unknown do
      raise ExUnit.AssertionError,
        message: """
        The handler returned a value Zizq does not recognise:

        #{inspect(result, pretty: true)}

        Expected one of:

          :ok
          {:ok, value}
          {:error, reason}
          {:cancel, reason}
          {:snooze, milliseconds} or {:snooze, %DateTime{}}

        A worker would acknowledge this job as complete and log a
        warning. Return one of the above, or assert on the value with
        something other than perform_job/3.
        """
    end
  end

  # Through JSON rather than by walking the term: this is the same
  # normalisation the payload gets on its way to the server, so what a
  # handler sees here is what it would see in production.
  defp normalise_payload(nil), do: nil
  defp normalise_payload(payload), do: JSON.decode!(JSON.encode!(payload))

  defp job(payload, opts) do
    %Zizq.Job{
      id: Keyword.get(opts, :id, synthetic_id()),
      type: Keyword.get(opts, :type),
      queue: Keyword.get(opts, :queue, "default"),
      status: :in_flight,
      payload: payload,
      attempts: Keyword.get(opts, :attempts, 0)
    }
  end

  # --- Draining ---

  @doc """
  Run every enqueued job through `handler`, and return how many ran.

  `handler` is what a worker takes: a one-argument function over a
  `Zizq.Job`, or a `Zizq.Router`.

      MyApp.Signup.run("ada@example.com")

      assert drain_enqueued(MyApp.Router.build()) == 1

  A job is drained once. Calling again runs only what has been
  enqueued since.

  ## Options

    * `:recursive` — keep going until nothing new is enqueued, so a
      handler that enqueues further jobs drains those too. Defaults to
      `false`, which runs only what was already enqueued when the call
      began.
    * `:max_iterations` — how many rounds `:recursive` may take before
      giving up, guarding against a handler that always enqueues and
      would otherwise hang the suite. Defaults to `1_000`.
    * `:type`, `:queue` — drain only matching jobs, as
      `assert_enqueued/1` matches.

  Handlers run in the calling process, one at a time, in the order the
  jobs were enqueued — so a test can reason about ordering in a way a
  real worker's concurrency would not allow. Anything a handler raises
  propagates, after the job is marked drained so a retry cannot loop
  on it.
  """
  @spec drain_enqueued(module() | Zizq.Router.t() | (Zizq.Job.t() -> term()), keyword()) ::
          non_neg_integer()
  def drain_enqueued(handler, opts \\ []) do
    {recursive, opts} = Keyword.pop(opts, :recursive, false)
    {max_iterations, filters} = Keyword.pop(opts, :max_iterations, 1_000)

    drain_loop(to_handler(handler), filters, recursive, max_iterations, 0, 0)
  end

  defp drain_loop(fun, filters, recursive, max_iterations, iterations, total) do
    case runnable(filters) do
      [] ->
        total

      snapshot ->
        Enum.each(snapshot, &run_drained(fun, &1))
        total = total + length(snapshot)

        cond do
          not recursive ->
            total

          iterations + 1 >= max_iterations ->
            raise ExUnit.AssertionError,
              message: """
              drain_enqueued/2 hit :max_iterations (#{max_iterations}).

              A handler is enqueueing another job every round, so
              draining never finishes. Raise :max_iterations if the
              fan-out is genuine, or drop `recursive: true` and drain
              in steps.
              """

          true ->
            drain_loop(fun, filters, recursive, max_iterations, iterations + 1, total)
        end
    end
  end

  # A snapshot, deliberately: jobs enqueued while this round runs are
  # left for the next one, so a handler cannot extend the list it is
  # being iterated over.
  defp runnable(filters) do
    drained = drained_ids()
    Enum.reject(all_enqueued(filters), &MapSet.member?(drained, &1["id"]))
  end

  defp drained_ids do
    owner = owner() || self()

    @table
    |> :ets.lookup({:drained, owner})
    |> MapSet.new(&elem(&1, 1))
  end

  defp run_drained(fun, recorded) do
    # Marked before running, not after: a handler that raises has still
    # had its turn, and a second drain must not run it again.
    :ets.insert(@table, {{:drained, owner() || self()}, recorded["id"]})

    recorded
    |> Zizq.Job.from_wire()
    |> fun.()
    |> tap(&assert_valid_outcome/1)
  end

  defp to_handler(%Zizq.Router{} = router), do: Zizq.Router.build(router)
  defp to_handler(fun) when is_function(fun, 1), do: fun

  defp to_handler(other) do
    raise ArgumentError,
          "expected a one-argument function over a Zizq.Job, or a Zizq.Router, " <>
            "got: #{inspect(other)}"
  end
end
