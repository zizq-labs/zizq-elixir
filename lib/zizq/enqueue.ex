# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Enqueue do
  @moduledoc """
  Job inputs to be enqueued.

  Building one sends nothing, so enqueues may compose: you may build
  many, then hand them to `Zizq.enqueue_all/2` in a single request bulk
  enqueue request.

      Zizq.Enqueue.new!(type: "send_email", payload: %{"user_id" => 42})

  ## Fields

    * `:type` — the job's type name used by the worker to route to an
      appropriate handler. **Required.** This is the string other
      languages would also enqueue to reach the same handler.
    * `:payload` — arbitrary JSON-compatible data processed by the
      worker. Defaults to `%{}`.
    * `:queue` — defaults to `"default"` on the client. The server
      requires a queue on every enqueue and has no default of its own.
    * `:priority` — 0 to 65535, lower runs first. Defaults to the
      middle of the range (32768) when not specified.
    * `:ready_at` — a `t:DateTime.t/0` (or Unix milliseconds) before
      which the job will not run. Creates it in the `:scheduled` state
      when set to a future date/time.
    * `:retry_limit` — number of attempts before the job is declared
      dead.
    * `:backoff` — a `Zizq.Backoff` policy, or a keyword list.
    * `:retention` — a `Zizq.Retention` policy, or a keyword list.
    * `:unique_key` — enqueue-time deduplication key: a string, or a
      `Zizq.PayloadHasher` to derive one from the payload. `:payload`
      and `{:payload, opts}` are shorthand for the latter. Requires a
      Pro licence on the server.
    * `:unique_while` — `:queued` (default), `:active`, or `:exists`.
    * `:batch` — a `Zizq.BatchConfig`, or a keyword list. Requires a
      Pro licence on the server.

  Anything left unset is omitted from the request, so the server's own
  defaults apply and continue to track its configuration.
  """

  alias Zizq.Backoff
  alias Zizq.BatchConfig
  alias Zizq.Retention

  @type t :: %__MODULE__{
          type: String.t(),
          queue: String.t(),
          payload: term(),
          priority: non_neg_integer() | nil,
          ready_at: DateTime.t() | integer() | nil,
          retry_limit: non_neg_integer() | nil,
          backoff: Backoff.t() | nil,
          retention: Retention.t() | nil,
          unique_key: String.t() | Zizq.PayloadHasher.t() | nil,
          unique_while: :queued | :active | :exists | nil,
          batch: BatchConfig.t() | nil,
          budgets: [Zizq.BudgetBinding.t()]
        }

  @enforce_keys [:type]
  defstruct [
    :type,
    :payload,
    :priority,
    :ready_at,
    :retry_limit,
    :backoff,
    :retention,
    :unique_key,
    :unique_while,
    :batch,
    queue: "default",
    budgets: []
  ]

  @keys ~w(type queue payload priority ready_at retry_limit backoff retention
           unique_key unique_while batch budgets)a

  @unique_scopes [:queued, :active, :exists]

  @doc """
  Build an enqueue from a keyword list or map.

  Unknown keys are rejected rather than ignored. Without that, a typo
  like `payloads:` would silently enqueue a job with an empty payload.
  """
  @spec new!(t() | keyword() | map()) :: t()
  # Normalised here too, not only on the attrs path: `:unique_key`
  # accepts the shorthand wherever it is set, and a struct built by
  # hand is no different from one built from a keyword list.
  def new!(%__MODULE__{} = enqueue) do
    validate!(%{
      enqueue
      | unique_key: hasher(enqueue.unique_key),
        budgets: bindings!(enqueue.budgets)
    })
  end

  def new!(attrs) do
    attrs = Map.new(attrs)

    case Map.keys(attrs) -- @keys do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown enqueue #{plural(unknown)}: #{inspect(unknown)}. " <>
                "Known keys are #{inspect(@keys)}"
    end

    %__MODULE__{
      type: Map.get(attrs, :type),
      queue: Map.get(attrs, :queue, "default"),
      payload: Map.get(attrs, :payload, %{}),
      priority: Map.get(attrs, :priority),
      ready_at: Map.get(attrs, :ready_at),
      retry_limit: Map.get(attrs, :retry_limit),
      backoff: attrs |> Map.get(:backoff) |> maybe(&Backoff.new!/1),
      retention: attrs |> Map.get(:retention) |> maybe(&Retention.new!/1),
      unique_key: attrs |> Map.get(:unique_key) |> hasher(),
      unique_while: Map.get(attrs, :unique_while),
      batch: attrs |> Map.get(:batch) |> maybe(&BatchConfig.new!/1),
      budgets: attrs |> Map.get(:budgets, []) |> bindings!()
    }
    |> validate!()
  end

  @doc false
  # The wire uses string keys, `type` rather than `job_type`, and
  # milliseconds for `ready_at`. Unset optional fields are omitted
  # entirely so the server applies its own defaults.
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = e) do
    optional =
      %{
        "priority" => e.priority,
        "ready_at" => Zizq.Timestamp.to_ms(e.ready_at),
        "retry_limit" => e.retry_limit,
        "backoff" => e.backoff && Backoff.to_wire(e.backoff),
        "retention" => e.retention && Retention.to_wire(e.retention),
        "unique_key" => unique_key(e),
        "unique_while" => e.unique_while && Atom.to_string(e.unique_while),
        "batch" => e.batch && BatchConfig.to_wire(e.batch, e.type, e.payload),
        "budgets" => budgets_to_wire(e.budgets)
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    # The required three are merged in separately rather than compacted
    # with the rest: the server requires all three on every enqueue, and
    # `null` is a legitimate payload, so `payload: nil` must still be
    # sent rather than dropped.
    Map.merge(%{"type" => e.type, "queue" => e.queue, "payload" => e.payload}, optional)
  end

  # An unthrottled job sends nothing rather than an empty array.
  defp budgets_to_wire([]), do: nil
  defp budgets_to_wire(bindings), do: Enum.map(bindings, &Zizq.BudgetBinding.to_wire/1)

  defp bindings!(nil), do: []

  defp bindings!(bindings) when is_list(bindings) do
    Enum.map(bindings, &Zizq.BudgetBinding.new!/1)
  end

  defp bindings!(other) do
    raise ArgumentError,
          "enqueue :budgets must be a list of budget bindings, got #{inspect(other)}"
  end

  defp validate!(%__MODULE__{} = e) do
    unless is_binary(e.type) and e.type != "" do
      raise ArgumentError,
            "enqueue :type is required and must be a non-empty string, got #{inspect(e.type)}"
    end

    unless is_binary(e.queue) and e.queue != "" do
      raise ArgumentError, "enqueue :queue must be a non-empty string, got #{inspect(e.queue)}"
    end

    if e.unique_while && e.unique_while not in @unique_scopes do
      raise ArgumentError,
            "enqueue :unique_while must be one of #{inspect(@unique_scopes)}, got #{inspect(e.unique_while)}"
    end

    unless is_nil(e.unique_key) or is_binary(e.unique_key) or
             is_struct(e.unique_key, Zizq.PayloadHasher) do
      raise ArgumentError,
            "enqueue :unique_key must be a string or a Zizq.PayloadHasher, " <>
              "got #{inspect(e.unique_key)}"
    end

    if e.unique_while && is_nil(e.unique_key) do
      raise ArgumentError, "enqueue :unique_while has no effect without :unique_key"
    end

    # The server rejects this combination on both the single and bulk
    # endpoints. Catching it here turns a round trip into an immediate
    # error at the call site that got it wrong.
    if e.unique_key && e.batch do
      raise ArgumentError, "enqueue :unique_key and :batch cannot be combined"
    end

    e
  end

  # Normalised at construction so the paths are parsed once per
  # enqueue rather than once per call to `to_wire/1`. Declared on a job
  # module, this runs while that module compiles, so they are parsed
  # once for the life of the program.
  defp hasher(value), do: Zizq.PayloadHasher.from_option(value)

  # Derived here rather than at construction because this is the first
  # point at which both the type and the payload it applies to are
  # settled — a job module supplies the hasher long before either.
  defp unique_key(%__MODULE__{unique_key: nil}), do: nil

  defp unique_key(%__MODULE__{} = e) do
    Zizq.PayloadHasher.resolve(e.unique_key, e.type, e.payload)
  end

  defp maybe(nil, _fun), do: nil
  defp maybe(value, fun), do: fun.(value)

  defp plural([_]), do: "key"
  defp plural(_), do: "keys"
end
