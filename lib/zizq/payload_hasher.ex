# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.PayloadHasher do
  @moduledoc """
  Derives a stable key from a job's payload.

  Used for unique keys, and for batch keys once those exist. The whole
  payload hashes by default; `:only` and `:except` narrow it to the
  parts that should decide identity:

      # Two enqueues with the same user and template are the same job.
      Zizq.PayloadHasher.new!(only: [".user_id", ".template"])

      # Everything except a timestamp that changes every call.
      Zizq.PayloadHasher.new!(except: [".requested_at"])

  Paths are jq-flavoured. Declared on a job module they are parsed when
  that module compiles, so a malformed path is a build failure and no
  enqueue pays to parse it:

      use Zizq.JobKind,
        type: "send_email",
        unique_key: {:payload, only: [".user_id", ".template"]},
        unique_while: :queued

  ## Paths

  | Path | Selects |
  | --- | --- |
  | `"."` | the whole payload |
  | `".user_id"` | a key |
  | `".user.id"` | a nested key |
  | `".items[0]"` | an array element |
  | `".[0]"` | an element of a root array |
  | `~s(.["dotted.key"])` | a key containing a dot |

  A path that matches nothing is skipped rather than treated as
  `null`, so payloads that omit an optional field still hash to the
  same key as those that never had it.

  ## How the digest is built

  The payload is first round-tripped through JSON, collapsing structs,
  atom keys, `DateTime`s and charlists into what the server actually
  stores. The result is then streamed into SHA-256 as canonical JSON:
  object keys sorted, arrays in order, with `{`, `}`, `[`, `]`, `:`
  and `,` markers so that `[1, 2]` and `[12]` cannot collide.

  `:erlang.term_to_binary/2` with `:deterministic` would be one line
  and much faster, but it hashes the Erlang representation rather than
  the value: `%{"a" => 1}` and `%{a: 1}` differ, as do `1` and `1.0`,
  none of which survives the trip to the server. It is also not frozen
  across OTP releases.

  ## Stability

  The digest is stable **within Elixir** across releases of this
  client, which is what uniqueness depends on. It is not guaranteed to
  equal the digest another language's client computes for the same
  payload: JSON does not distinguish `1` from `1.0` but Elixir does, so
  a float that another runtime would render as `1` renders here as
  `1.0`. Dedupe within one producer, not across producers in different
  languages.
  """

  @type step :: {:key, String.t()} | {:index, non_neg_integer()}

  @type t :: %__MODULE__{
          only: [[step()]] | nil,
          except: [[step()]] | nil,
          prefix: boolean()
        }

  defstruct only: nil, except: nil, prefix: true

  @doc """
  Build a hasher, parsing its paths.

  ## Options

    * `:only` — a path or list of paths whose values decide the key.
    * `:except` — a path or list of paths to leave out. Cannot be
      combined with `:only`.
    * `:prefix` — prefix the key with the job type and a `:`. Defaults
      to `true`, which keeps two kinds of job with identical payloads
      from colliding.
  """
  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    opts = Keyword.validate!(opts, only: nil, except: nil, prefix: true)
    only = opts[:only]
    except = opts[:except]

    if only && except do
      raise ArgumentError, "`:only` and `:except` cannot be combined"
    end

    %__MODULE__{
      only: only && Enum.map(List.wrap(only), &parse_path!/1),
      except: except && Enum.map(List.wrap(except), &parse_path!/1),
      prefix: opts[:prefix]
    }
  end

  @doc """
  Build the key for a job of `type` carrying `payload`.
  """
  @spec key(t(), String.t(), term()) :: String.t()
  def key(%__MODULE__{} = hasher, type, payload) do
    if hasher.prefix, do: "#{type}:#{digest(hasher, payload)}", else: digest(hasher, payload)
  end

  @doc """
  Build the bare hex digest for `payload`, without a type prefix.
  """
  @spec digest(t(), term()) :: String.t()
  def digest(%__MODULE__{} = hasher, payload) do
    hasher
    |> hashable(payload)
    |> hash()
    |> Base.encode16(case: :lower)
  end

  @doc false
  # Accepts the shorthand a caller may write in place of a hasher, so
  # `:unique_key` and a batch's `:key` take the same forms. Anything
  # else passes through for its own option to validate.
  @spec from_option(term()) :: term()
  def from_option({:payload, opts}) when is_list(opts), do: new!(opts)
  def from_option(:payload), do: new!()
  def from_option(other), do: other

  @doc false
  # Applied at wire time rather than construction: a hasher is declared
  # long before the payload it will be applied to, often while the job
  # module is still compiling.
  @spec resolve(String.t() | t(), String.t(), term()) :: String.t()
  def resolve(%__MODULE__{} = hasher, type, payload), do: key(hasher, type, payload)
  def resolve(key, _type, _payload) when is_binary(key), do: key

  # --- Selecting what participates ---

  defp hashable(hasher, payload) do
    # Normalised first so that what is hashed is what the server would
    # store, rather than whatever Elixir happened to be holding.
    normalised = JSON.decode!(JSON.encode!(payload))

    cond do
      hasher.only -> pick(normalised, hasher.only)
      hasher.except -> Enum.reduce(hasher.except, normalised, &delete(&2, &1))
      true -> normalised
    end
  end

  # Rebuilds the selected parts with their nesting intact, so
  # `only: [".user.id"]` hashes `%{"user" => %{"id" => _}}` rather than
  # a bare value that a differently-nested payload could collide with.
  defp pick(source, paths) do
    Enum.reduce_while(paths, nil, fn
      # `.` selects everything, so nothing else can narrow it.
      [], _acc ->
        {:halt, source}

      steps, acc ->
        case walk(source, steps) do
          :missing -> {:cont, acc}
          {:ok, value} -> {:cont, put_in_path(acc, steps, value)}
        end
    end)
    |> case do
      # Every path missing. An empty object keeps the digest total, and
      # equal to what an empty selection would produce.
      nil -> %{}
      picked -> picked
    end
  end

  defp put_in_path(target, [step | _] = steps, value) do
    do_put(target || empty_for(step), steps, value)
  end

  defp do_put(container, [step], value), do: put_step(container, step, value)

  defp do_put(container, [step, next | rest], value) do
    child = get_step(container, step) || empty_for(next)
    put_step(container, step, do_put(child, [next | rest], value))
  end

  defp empty_for({:key, _}), do: %{}
  defp empty_for({:index, _}), do: []

  defp get_step(map, {:key, name}) when is_map(map), do: Map.get(map, name)
  defp get_step(list, {:index, i}) when is_list(list), do: Enum.at(list, i)
  defp get_step(_other, _step), do: nil

  defp put_step(map, {:key, name}, value) when is_map(map), do: Map.put(map, name, value)

  # Sparse indexes are padded with nulls: the position has to survive,
  # or `.items[2]` and `.items[0]` would produce the same shape.
  defp put_step(list, {:index, i}, value) when is_list(list) do
    # Padded to `i + 1`, not `i`: `List.replace_at/3` is a silent no-op
    # when the index is out of bounds, so one element short leaves the
    # value out of the digest entirely.
    padded = list ++ List.duplicate(nil, max(0, i + 1 - length(list)))
    List.replace_at(padded, i, value)
  end

  defp walk(value, []), do: {:ok, value}

  defp walk(map, [{:key, name} | rest]) when is_map(map) do
    case Map.fetch(map, name) do
      {:ok, value} -> walk(value, rest)
      :error -> :missing
    end
  end

  defp walk(list, [{:index, i} | rest]) when is_list(list) and i < length(list) do
    walk(Enum.at(list, i), rest)
  end

  defp walk(_value, _steps), do: :missing

  # `except: ["."]` removes everything, so every payload collapses to
  # the same digest rather than the operation being undefined.
  defp delete(_value, []), do: nil

  defp delete(map, [{:key, name}]) when is_map(map), do: Map.delete(map, name)

  defp delete(list, [{:index, i}]) when is_list(list) and i < length(list),
    do: List.delete_at(list, i)

  defp delete(map, [{:key, name} | rest]) when is_map(map) do
    case Map.fetch(map, name) do
      {:ok, child} -> Map.put(map, name, delete(child, rest))
      :error -> map
    end
  end

  defp delete(list, [{:index, i} | rest]) when is_list(list) and i < length(list) do
    List.replace_at(list, i, delete(Enum.at(list, i), rest))
  end

  # A path that does not lead anywhere removes nothing.
  defp delete(value, _steps), do: value

  # --- Canonical hashing ---

  defp hash(value) do
    :sha256
    |> :crypto.hash_init()
    |> hash_into(value)
    |> :crypto.hash_final()
  end

  defp hash_into(ctx, value) when is_map(value) do
    ctx = :crypto.hash_update(ctx, "{")

    value
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(ctx, fn {key, item}, ctx ->
      ctx
      |> :crypto.hash_update(JSON.encode!(key))
      |> :crypto.hash_update(":")
      |> hash_into(item)
      |> :crypto.hash_update(",")
    end)
    |> :crypto.hash_update("}")
  end

  defp hash_into(ctx, value) when is_list(value) do
    ctx = :crypto.hash_update(ctx, "[")

    value
    |> Enum.reduce(ctx, fn item, ctx ->
      ctx |> hash_into(item) |> :crypto.hash_update(",")
    end)
    |> :crypto.hash_update("]")
  end

  defp hash_into(ctx, value), do: :crypto.hash_update(ctx, JSON.encode!(value))

  # --- Path parsing ---

  @doc """
  Parse a jq-flavoured path into steps.

  Called while a job module compiles, so a bad path fails the build.
  """
  @spec parse_path!(String.t()) :: [step()]
  def parse_path!("."), do: []

  def parse_path!("." <> rest = path), do: parse_steps(rest, path, [])

  def parse_path!(path) do
    raise ArgumentError, "a payload path must start with '.', got: #{inspect(path)}"
  end

  defp parse_steps("", _path, acc), do: Enum.reverse(acc)

  defp parse_steps("." <> rest, path, acc), do: parse_steps(rest, path, acc)

  defp parse_steps("[\"" <> rest, path, acc) do
    {name, rest} = quoted_key(rest, path, "")
    parse_steps(rest, path, [{:key, name} | acc])
  end

  defp parse_steps("[" <> rest, path, acc) do
    case Integer.parse(rest) do
      {index, "]" <> rest} when index >= 0 ->
        parse_steps(rest, path, [{:index, index} | acc])

      _ ->
        raise ArgumentError, "invalid array index in payload path #{inspect(path)}"
    end
  end

  defp parse_steps(<<char::utf8, _::binary>> = rest, path, acc) do
    if name_start?(char) do
      {name, rest} = name(rest, "")
      parse_steps(rest, path, [{:key, name} | acc])
    else
      raise ArgumentError,
            "unexpected #{inspect(<<char::utf8>>)} in payload path #{inspect(path)}"
    end
  end

  defp quoted_key("\"]" <> rest, _path, acc), do: {acc, rest}

  # Any character can be escaped, which is what makes a key containing
  # a quote reachable at all.
  defp quoted_key(<<?\\, char::utf8, rest::binary>>, path, acc) do
    quoted_key(rest, path, acc <> <<char::utf8>>)
  end

  defp quoted_key(<<char::utf8, rest::binary>>, path, acc) do
    quoted_key(rest, path, acc <> <<char::utf8>>)
  end

  defp quoted_key("", path, _acc) do
    raise ArgumentError, "unterminated quoted key in payload path #{inspect(path)}"
  end

  defp name(<<char::utf8, rest::binary>> = source, acc) do
    if name_char?(char), do: name(rest, acc <> <<char::utf8>>), else: {acc, source}
  end

  defp name("", acc), do: {acc, ""}

  defp name_start?(char), do: char in ?a..?z or char in ?A..?Z or char == ?_
  defp name_char?(char), do: name_start?(char) or char in ?0..?9
end
