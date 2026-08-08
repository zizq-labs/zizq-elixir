# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Config do
  @moduledoc """
  Validated configuration for a running `Zizq` client.

  Built once when the client starts and read on every request, so it is
  kept in `:persistent_term` rather than behind a process. A lookup is
  then a direct memory read with no message pass on the hot path.
  """

  @schema [
    name: [
      type: :atom,
      required: true,
      doc: """
      Name for this client instance. Also names the supervisor, and is
      the handle passed to `Zizq.enqueue/2` and friends.
      """
    ],
    url: [
      type: :string,
      required: true,
      doc: """
      Base URL of the Zizq server, e.g. `"http://localhost:7890"`. A
      path is allowed and is treated as a prefix, for servers behind a
      reverse proxy.
      """
    ],
    format: [
      type: :atom,
      default: :msgpack,
      doc: """
      Serialization format: `:msgpack` (default), `:json`, or a module
      implementing the `Zizq.Codec` behaviour.
      """
    ],
    pool_count: [
      type: :pos_integer,
      default: 1,
      doc: """
      Number of HTTP/2 connections to the server. Each is fully
      multiplexed, so one is usually enough; raise it only if a single
      connection becomes a bottleneck.
      """
    ],
    connect_timeout: [
      type: :timeout,
      default: 5_000,
      doc: "Milliseconds to wait for a connection to be established."
    ],
    receive_timeout: [
      type: :timeout,
      default: 15_000,
      doc: "Milliseconds to wait for a response. Does not apply to the take stream."
    ]
  ]

  @type t :: %__MODULE__{
          name: atom(),
          url: String.t(),
          codec: Zizq.Codec.t(),
          finch_name: atom(),
          pool_count: pos_integer(),
          connect_timeout: timeout(),
          receive_timeout: timeout()
        }

  defstruct [
    :name,
    :url,
    :codec,
    :finch_name,
    :pool_count,
    :connect_timeout,
    :receive_timeout
  ]

  @doc false
  def schema, do: @schema

  @doc """
  Validate raw options and build a config struct.

  Raises `NimbleOptions.ValidationError` on invalid options, or
  `ArgumentError` for a malformed URL or unknown codec.
  """
  @spec new!(keyword()) :: t()
  def new!(opts) do
    opts = NimbleOptions.validate!(opts, @schema)
    name = Keyword.fetch!(opts, :name)

    %__MODULE__{
      name: name,
      url: normalise_url!(Keyword.fetch!(opts, :url)),
      codec: Zizq.Codec.fetch!(Keyword.fetch!(opts, :format)),
      finch_name: Module.concat(name, Finch),
      pool_count: Keyword.fetch!(opts, :pool_count),
      connect_timeout: Keyword.fetch!(opts, :connect_timeout),
      receive_timeout: Keyword.fetch!(opts, :receive_timeout)
    }
  end

  @doc "Store the config for `name`. Called by the supervisor at startup."
  @spec put(t()) :: :ok
  def put(%__MODULE__{name: name} = config), do: :persistent_term.put(key(name), config)

  @doc "Remove a stored config, so repeated start/stop cycles don't accumulate."
  @spec delete(atom()) :: boolean()
  def delete(name), do: :persistent_term.erase(key(name))

  @doc """
  Look up the config for a running client.

  Raises with an actionable message if the client isn't running, which
  is by far the most common way to get this wrong.
  """
  @spec fetch!(atom()) :: t()
  def fetch!(name) when is_atom(name) do
    :persistent_term.get(key(name))
  rescue
    ArgumentError ->
      reraise ArgumentError,
              """
              no Zizq client named #{inspect(name)} is running.

              Add one to your supervision tree:

                  children = [
                    {Zizq, name: #{inspect(name)}, url: "http://localhost:7890"}
                  ]
              """,
              __STACKTRACE__
  end

  defp key(name), do: {__MODULE__, name}

  # Trailing slashes are stripped so `url <> "/jobs"` can't produce a
  # double slash. A path is kept as a prefix for proxied deployments.
  defp normalise_url!(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) ->
        String.trim_trailing(url, "/")

      _ ->
        raise ArgumentError,
              "expected :url to be an http or https URL with a host, got: #{inspect(url)}"
    end
  end
end
