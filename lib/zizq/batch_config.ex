# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.BatchConfig do
  @moduledoc """
  Batching configuration: fold an enqueue into an existing `:ready` job
  rather than creating a new one.

  Say where the batch accumulates and how large it may get, and the
  rest follows:

      # Cap `.device_ids` at 100 entries per batch.
      Zizq.BatchConfig.new!(limit: 100, path: ".device_ids")

      # The whole payload is the batch, and is an array.
      Zizq.BatchConfig.new!(limit: 1_000)

  Declared on a job module, an enqueue then carries only its own
  contribution and the server merges it:

      defmodule MyApp.PushBatch do
        use Zizq.JobKind,
          type: "push",
          queue: "push",
          batch: [limit: 100, path: ".device_ids"]

        @impl Zizq.JobKind
        def perform(%{"device_ids" => ids}), do: MyApp.Push.deliver(ids)
      end

      MyApp.PushBatch.new(%{"device_ids" => [id], "platform" => "apple"})
      |> Zizq.enqueue(MyApp.Zizq)

  ## What gets generated

  | Option | Becomes |
  | --- | --- |
  | `:limit` and `:path` | the `:when` predicate |
  | `:path`, `:dedup`, `:sorted` | the `:fold` expression |
  | `:path` | the default `:key`, hashing everything *except* the batch |

  `:key` defaulting to the payload minus the batch path is what makes
  the common case work without saying anything: two enqueues alike in
  every respect *but* what they contribute belong in the same batch.
  In the example above, `platform` decides the batch and `device_ids`
  accumulates into it.

  `:dedup` folds with jq's `unique`, `:sorted` with `sort`. `unique`
  also sorts, so `:dedup` subsumes `:sorted`.

  ## Options

    * `:limit` — maximum combined length at `:path` before the batch is
      sealed and a new one starts.
    * `:path` — jq path to the value that accumulates. Defaults to
      `"."`, the whole payload.
    * `:key` — override the derived key with a string, or another
      `Zizq.PayloadHasher`.
    * `:dedup` — fold with `unique`.
    * `:sorted` — fold with `sort`.

  ## Writing the expressions by hand

  `:key`, `:when` and `:fold` can be given directly instead, for folds
  the templates do not cover — accumulating into a map, say, or
  counting rather than appending:

      Zizq.BatchConfig.new!(
        key: "digest:tenant-42",
        when: "$existing.count < 100",
        fold: "$existing | .count += 1 | .ids += $new.ids"
      )

  Both are jq, evaluated with `$existing` bound to the batch's current
  payload and `$new` to the incoming one. `:limit` and `:path` cannot
  be mixed with them, since they would be generating the same fields.

  Batching is a Pro-licensed feature; without one the server responds
  403, which surfaces as `%Zizq.Error{reason: :forbidden}`.

  The configuration is returned on job reads, and the *first* enqueue's
  `:when` and `:fold` govern the whole batch — so reading back what is
  stored is how a "first wins" surprise gets diagnosed.
  """

  @type t :: %__MODULE__{
          key: String.t() | Zizq.PayloadHasher.t(),
          when: String.t(),
          fold: String.t()
        }

  @enforce_keys [:key, :when, :fold]
  defstruct [:key, :when, :fold]

  @generated [:limit, :path, :dedup, :sorted, :key]
  @manual [:key, :when, :fold]

  @doc """
  Build a batch configuration from a keyword list or map.

  See the module documentation for the options.
  """
  @spec new!(t() | keyword() | map()) :: t()
  def new!(%__MODULE__{} = batch), do: batch

  def new!(attrs) do
    attrs = Map.new(attrs)

    case Map.keys(attrs) -- (@generated ++ @manual) do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown batch keys: #{inspect(unknown)}"
    end

    if Map.has_key?(attrs, :limit), do: generated!(attrs), else: manual!(attrs)
  end

  # Templated from a path and a cap. The pipe form (`$existing | .path`)
  # rather than `$existing.path` because it is the one shape that also
  # works for the root path, where `$existing.` is a syntax error.
  # Matches the Node and Rust clients expression for expression.
  defp generated!(attrs) do
    Enum.each([:when, :fold], fn field ->
      if Map.has_key?(attrs, field) do
        raise ArgumentError,
              "batch #{inspect(field)} is generated from :limit and :path; " <>
                "give either :limit and :path, or :key, :when and :fold, not both"
      end
    end)

    limit = limit!(attrs)
    path = path!(attrs)

    %__MODULE__{
      key: generated_key!(attrs, path),
      when: "(($existing | #{path}) + ($new | #{path})) | length <= #{limit}",
      fold: fold(path, attrs)
    }
  end

  defp fold(path, %{dedup: true}),
    do: "$existing | #{path} = ((#{path}) + ($new | #{path}) | unique)"

  defp fold(path, %{sorted: true}),
    do: "$existing | #{path} = ((#{path}) + ($new | #{path}) | sort)"

  defp fold(path, _attrs), do: "$existing | #{path} += ($new | #{path})"

  defp manual!(attrs) do
    %__MODULE__{
      key: fetch_key!(attrs),
      when: fetch_string!(attrs, :when),
      fold: fetch_string!(attrs, :fold)
    }
  end

  defp limit!(attrs) do
    case Map.fetch!(attrs, :limit) do
      limit when is_integer(limit) and limit > 0 ->
        limit

      other ->
        raise ArgumentError, "batch :limit must be a positive integer, got #{inspect(other)}"
    end
  end

  defp path!(attrs) do
    path = Map.get(attrs, :path, ".")

    unless is_binary(path) do
      raise ArgumentError, "batch :path must be a string, got #{inspect(path)}"
    end

    # Parsed for its errors, not its result: a typo here would otherwise
    # reach the server as a jq expression that silently matches nothing.
    _ = Zizq.PayloadHasher.parse_path!(path)

    path
  end

  # Everything but the batch itself decides which batch this is. Two
  # enqueues alike apart from what they contribute belong together.
  defp generated_key!(attrs, path) do
    case Map.fetch(attrs, :key) do
      {:ok, _key} -> fetch_key!(attrs)
      :error -> Zizq.PayloadHasher.new!(except: [path])
    end
  end

  @doc false
  # Takes the type and payload because `:key` may be a hasher, which
  # cannot be resolved until there is a payload to resolve it against.
  @spec to_wire(t(), String.t(), term()) :: map()
  def to_wire(%__MODULE__{} = b, type, payload) do
    %{
      "key" => Zizq.PayloadHasher.resolve(b.key, type, payload),
      "when" => b.when,
      "fold" => b.fold
    }
  end

  @doc false
  @spec from_wire(map()) :: t()
  def from_wire(%{"key" => key, "when" => when_expr, "fold" => fold}) do
    %__MODULE__{key: key, when: when_expr, fold: fold}
  end

  defp fetch_key!(attrs) do
    case attrs |> Map.get(:key) |> Zizq.PayloadHasher.from_option() do
      %Zizq.PayloadHasher{} = hasher ->
        hasher

      key when is_binary(key) and key != "" ->
        key

      nil ->
        raise ArgumentError, "batch :key is required"

      other ->
        raise ArgumentError,
              "batch :key must be a non-empty string or a Zizq.PayloadHasher, " <>
                "got #{inspect(other)}"
    end
  end

  defp fetch_string!(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        value

      {:ok, other} ->
        raise ArgumentError,
              "batch #{inspect(key)} must be a non-empty string, got #{inspect(other)}"

      :error ->
        raise ArgumentError, "batch #{inspect(key)} is required"
    end
  end
end
