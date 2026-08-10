# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Router do
  @moduledoc """
  Dispatches jobs to the module that defines them, by type.

  Pass one straight to a worker as its `:handler`:

      {Zizq.Worker,
       client: MyApp.Zizq,
       queues: ["emails", "reports"],
       handler: Zizq.Router.new([MyApp.SendEmail, MyApp.GenerateReport])}

  Each module is asked for its `type/0` as it is registered, so the
  routing table is built once at startup rather than per job. Two
  modules in one list claiming the same type raises `ArgumentError`.

  Plain functions can be registered too:

      Zizq.Router.new([
        MyApp.SendEmail,
        {"ping", fn _payload -> :ok end},
        {"audit", fn payload, job -> MyApp.Audit.record(payload, job.id) end}
      ])

  ## Building a route at a time

  `route/2` and `route/3` add to a router, so routes can be assembled
  conditionally rather than declared all at once:

      Zizq.Router.new()
      |> Zizq.Router.route(MyApp.SendEmail)
      |> Zizq.Router.route("charge_card", &MyApp.Billing.charge/2)
      |> Zizq.Router.fallback(&MyApp.unknown_job/1)

  Unlike a list — where a repeated type is a mistake and raises —
  **`route/2` and `route/3` replace** any route already registered for
  that type. That is what makes a router of shared defaults useful as a
  starting point:

      base_router() |> Zizq.Router.route("charge_card", &test_double/1)

  ## Unrecognised types

  A job whose type is in no route raises `Zizq.Router.UnknownJobType`,
  which the worker reports as a failure like any other exception, so
  the job retries, and dies once its retry limit is spent. Retrying is
  usually right: during a rolling deploy a job enqueued by new code can
  reach a worker running old code, and the retry lands on a worker that
  knows the type. Or occasionally a bug is introduced and detected in
  your error tracker so you have time to rectify it.

  A fallback handles those instead of raising. It is optional, and
  receives the whole `Zizq.Job`, since a payload alone says little
  about a job you did not expect:

      Zizq.Router.new(modules) |> Zizq.Router.fallback(&MyApp.unknown/1)

  A fallback takes the same argument a handler does, so one router can
  defer to another:

      Zizq.Router.fallback(specific, Zizq.Router.build(general))

  ## Why types are registered, never resolved

  Turning a wire type into a module at runtime would mean
  `String.to_existing_atom/1` on data from the queue. Building a table
  from modules the application named itself keeps job data as something
  looked *up*, never something that selects code to run.
  """

  defmodule UnknownJobType do
    @moduledoc """
    Raised when a job's type matches no registered route.
    """

    defexception [:type]

    @impl true
    def message(%{type: type}), do: "no handler registered for job type #{inspect(type)}"
  end

  @type route :: (term() -> term()) | (term(), Zizq.Job.t() -> term())
  @type entry :: module() | {String.t(), route()}

  @type t :: %__MODULE__{
          routes: %{optional(String.t()) => (term(), Zizq.Job.t() -> term())},
          fallback: (Zizq.Job.t() -> term()) | nil
        }

  defstruct routes: %{}, fallback: nil

  @doc """
  Build a router from a list of job modules.

  ## Options

    * `:fallback` — a one-argument function called with the `Zizq.Job`
      when no route matches, instead of raising.
  """
  @spec new([entry()], keyword()) :: t()
  def new(entries \\ [], opts \\ []) when is_list(entries) and is_list(opts) do
    router = %__MODULE__{routes: table(entries)}

    case Keyword.fetch(opts, :fallback) do
      {:ok, fun} -> fallback(router, fun)
      :error -> router
    end
  end

  @doc """
  Register a module that uses `Zizq.JobKind`, under its own type.
  """
  @spec route(t(), module()) :: t()
  def route(%__MODULE__{} = router, module) when is_atom(module) do
    put(router, entry(module))
  end

  @doc """
  Register a handler for `type`.

  The handler takes the payload, or the payload and the `Zizq.Job`.
  Replaces any route already registered for that type.
  """
  @spec route(t(), String.t(), route()) :: t()
  def route(%__MODULE__{} = router, type, fun) when is_binary(type) and is_function(fun) do
    put(router, entry({type, fun}))
  end

  @doc """
  Handle jobs matching no route with `fun`, instead of raising.

  Replaces any fallback already registered.
  """
  @spec fallback(t(), (Zizq.Job.t() -> term())) :: t()
  def fallback(%__MODULE__{} = router, fun) do
    unless is_function(fun, 1) do
      raise ArgumentError,
            "expected a fallback taking one argument, the job, got: #{inspect(fun)}"
    end

    %{router | fallback: fun}
  end

  @doc """
  Compile a router into a one-argument function.

  `Zizq.Worker` does this once when it starts, so a router can be given
  to it directly. Call it yourself to hold a plain function (e.g. to use
  as another router's fallback, or to dispatch without a worker).
  """
  @spec build(t()) :: (Zizq.Job.t() -> term())
  def build(%__MODULE__{routes: routes, fallback: fallback}) do
    fn %Zizq.Job{} = job ->
      case Map.fetch(routes, job.type) do
        {:ok, fun} -> fun.(job.payload, job)
        :error when is_function(fallback, 1) -> fallback.(job)
        :error -> raise UnknownJobType, type: job.type
      end
    end
  end

  defp put(%__MODULE__{} = router, {type, fun}) do
    %{router | routes: Map.put(router.routes, type, fun)}
  end

  # A list is one declaration, so a repeated type in it is a mistake
  # rather than an override, unlike `route/3`, where replacing is the
  # point.
  defp table(entries) do
    entries
    |> Enum.map(&entry/1)
    |> Enum.reduce(%{}, fn {type, fun}, table ->
      if Map.has_key?(table, type) do
        raise ArgumentError,
              "more than one handler registered for job type #{inspect(type)}"
      end

      Map.put(table, type, fun)
    end)
  end

  defp entry(module) when is_atom(module) do
    Code.ensure_loaded!(module)

    unless function_exported?(module, :__zizq_perform__, 2) do
      raise ArgumentError,
            "#{inspect(module)} cannot be routed to because it does not " <>
              "`use Zizq.JobKind`. Register it as {type, fun} instead, or add " <>
              "`use Zizq.JobKind, type: \"...\"` to the module."
    end

    {module.type(), &module.__zizq_perform__/2}
  end

  defp entry({type, fun}) when is_binary(type) and is_function(fun) do
    case Function.info(fun, :arity) do
      # Normalised to arity 2 here rather than branched on per job, so
      # the cost lands once at registration.
      {:arity, 1} -> {type, fn payload, _job -> fun.(payload) end}
      {:arity, 2} -> {type, fun}
      {:arity, n} -> raise ArgumentError, arity_error(type, n)
    end
  end

  defp entry(other) do
    raise ArgumentError,
          "expected a module using Zizq.JobKind, or a {type, function} tuple, " <>
            "got: #{inspect(other)}"
  end

  defp arity_error(type, arity) do
    "the handler for job type #{inspect(type)} must take either the payload, " <>
      "or the payload and the job, but takes #{arity} arguments"
  end
end
