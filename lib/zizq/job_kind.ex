# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.JobKind do
  @moduledoc """
  Defines a kind of job: its name on the server, the enqueue options it
  defaults to, and what running it does.

      defmodule MyApp.SendEmail do
        use Zizq.JobKind,
          type: "send_email",
          queue: "emails",
          retry_limit: 5

        @impl Zizq.JobKind
        def perform(%{"user_id" => id, "template" => template}) do
          MyApp.Mailer.deliver(id, template)
        end
      end

  `use` generates `type/0`, `new/1` and `new/2` on the module. Building
  an enqueue and sending it stay separate, so enqueues compose:

      MyApp.SendEmail.new(%{"user_id" => 42})
      |> Zizq.enqueue(MyApp.Zizq)

      users
      |> Enum.map(&MyApp.SendEmail.new(%{"user_id" => &1.id}))
      |> Zizq.enqueue_all(MyApp.Zizq)

  `new/2` takes per-enqueue overrides on top of the module's defaults:

      MyApp.SendEmail.new(%{"user_id" => 42}, priority: 10)

  ## Options

  `:type` is the job's name on the server — the `"type"` field a
  producer written in any language sends to reach this handler. It is
  **required and never inferred from the module name**, so renaming
  `MyApp.SendEmail` cannot silently change the wire contract and strand
  every queued job.

  Everything else is optional and is any key `Zizq.Enqueue` accepts
  except `:payload`, which belongs to the individual enqueue rather
  than the kind. Options are validated when the module compiles, so a
  malformed `:backoff` is a build failure rather than a surprise at the
  first enqueue.

  `:queue` defaults to `"default"` in the client. Anything left unset
  is omitted from the request entirely, so the server's own defaults
  apply and keep tracking its configuration.

  ## `perform/1` and `perform/2`

  Define whichever you need. `perform/2` also receives the
  `Zizq.Job`, for the attempt count, id, queue, etc:

      @impl Zizq.JobKind
      def perform(payload, %Zizq.Job{attempts: attempts}) when attempts >= 3 do
        MyApp.Mailer.deliver_without_retry(payload)
      end

      def perform(payload, _job), do: MyApp.Mailer.deliver(payload)

  `:attempts` counts attempts that have already finished, so it is `0`
  while a job runs for the first time and the guard above first matches
  on the fourth run.

  Defining both is fine — `perform/2` wins. Defining neither fails at
  compile time. The choice is resolved while the module compiles, so
  dispatch costs nothing at runtime.

  See `Zizq.Worker` for what a return value does to the job.

  ## Producing without consuming

  A module is only worth defining where the job is *run*. An
  application that merely enqueues work handled elsewhere — by another
  service, or another language — has no `perform` to write, and should
  build enqueues with `Zizq.Enqueue` directly.
  """

  @type result ::
          :ok
          | {:ok, term()}
          | {:error, term()}
          | {:cancel, term()}
          | {:snooze, non_neg_integer() | DateTime.t()}

  @doc """
  Run the job, given its payload.
  """
  @callback perform(payload :: term()) :: result()

  @doc """
  Run the job, given its payload and the `Zizq.Job` it came from.
  """
  @callback perform(payload :: term(), job :: Zizq.Job.t()) :: result()

  @optional_callbacks perform: 1, perform: 2

  defmacro __using__(opts) do
    quote do
      @behaviour Zizq.JobKind
      @before_compile Zizq.JobKind

      # Evaluated while the using module compiles, which is what makes
      # `:timer.seconds(15)` in an option a compile-time constant and a
      # malformed `:backoff` a compile-time failure.
      {zizq_type, zizq_defaults} = Zizq.JobKind.__defaults__!(__MODULE__, unquote(opts))

      @zizq_type zizq_type
      @zizq_defaults zizq_defaults

      @doc """
      This job's type on the server: `#{inspect(@zizq_type)}`.
      """
      @spec type() :: String.t()
      def type, do: @zizq_type

      @doc """
      Build an enqueue for this job, without sending it.

      `opts` overrides the module's defaults for this one enqueue.
      """
      @spec new(term(), keyword()) :: Zizq.Enqueue.t()
      def new(payload, opts \\ []) do
        Zizq.JobKind.__new__(@zizq_defaults, payload, opts)
      end
    end
  end

  defmacro __before_compile__(env) do
    one? = Module.defines?(env.module, {:perform, 1})
    two? = Module.defines?(env.module, {:perform, 2})

    cond do
      # Prefer /2 when both exist: defining a /1 convenience wrapper
      # alongside is ordinary Elixir, not a mistake to reject.
      two? ->
        quote do
          @doc false
          def __zizq_perform__(payload, job), do: perform(payload, job)
        end

      one? ->
        quote do
          @doc false
          def __zizq_perform__(payload, _job), do: perform(payload)
        end

      true ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description:
            "#{inspect(env.module)} uses Zizq.JobKind but defines neither " <>
              "perform/1 nor perform/2"
    end
  end

  @doc false
  def __defaults__!(module, opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError,
            "#{inspect(module)} must pass a keyword list to `use Zizq.JobKind`, " <>
              "got: #{inspect(opts)}"
    end

    {type, rest} = Keyword.pop(opts, :type)

    unless is_binary(type) and type != "" do
      raise ArgumentError,
            "#{inspect(module)} must pass a non-empty string `:type` to " <>
              "`use Zizq.JobKind`, got: #{inspect(type)}"
    end

    # Rejected by name rather than left to the unknown-key error, which
    # would list `:payload` among the valid keys and read as though it
    # belonged here.
    if Keyword.has_key?(rest, :payload) do
      raise ArgumentError,
            "#{inspect(module)} passed `:payload` to `use Zizq.JobKind`. A payload " <>
              "belongs to a single enqueue, not to the kind — pass it to new/1 instead."
    end

    {type, Zizq.Enqueue.new!([{:type, type} | rest])}
  end

  @doc false
  def __new__(defaults, payload, opts) do
    opts = Map.new(opts)

    # Overriding the type would route the job to a different handler
    # than the module it was built from, which is never what was meant.
    if Map.has_key?(opts, :type) do
      raise ArgumentError,
            "cannot override :type when building a #{inspect(defaults.type)} job; " <>
              "a job's type is fixed by the module that defines it"
    end

    defaults
    |> Map.from_struct()
    |> Map.merge(opts)
    |> Map.put(:payload, payload)
    |> Zizq.Enqueue.new!()
  end
end
