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
      type: {:or, [:string, {:struct, URI}]},
      required: true,
      doc: """
      Base URL of the Zizq server, e.g. `"http://localhost:7890"`, as a
      string or a `URI`. A path is allowed and is treated as a prefix,
      for servers behind a reverse proxy.
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
      doc: "Milliseconds to wait for a response. Does not apply to streaming endpoints."
    ],
    stream_idle_timeout: [
      type: :timeout,
      default: 30_000,
      doc: """
      Milliseconds a streaming connection may go without any data
      before it is treated as dead and reconnected.

      The server sends heartbeat frames on an otherwise idle stream
      specifically so this can be detected, so the timeout only has to
      exceed that interval. The default is ten times the server's own
      default of three seconds. Raise it if the server runs with a
      longer heartbeat interval, since a timeout shorter than the
      heartbeat would reconnect a perfectly healthy connection on a
      loop.
      """
    ]
  ]

  @type t :: %__MODULE__{
          name: atom(),
          uri: URI.t(),
          codec: Zizq.Codec.t(),
          finch_name: atom(),
          pool_count: pos_integer(),
          connect_timeout: timeout(),
          receive_timeout: timeout(),
          stream_idle_timeout: timeout()
        }

  defstruct [
    :name,
    :uri,
    :codec,
    :finch_name,
    :pool_count,
    :connect_timeout,
    :receive_timeout,
    :stream_idle_timeout
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
      # Stored parsed rather than as a string. The take stream needs
      # scheme, host and port separately for `Mint.HTTP.connect/4`, and
      # `Finch.build/5` accepts a `URI` directly — passing one skips
      # the `URI.parse/1` it would otherwise run on every request.
      uri: normalise_uri!(Keyword.fetch!(opts, :url)),
      codec: Zizq.Codec.fetch!(Keyword.fetch!(opts, :format)),
      finch_name: Module.concat(name, Finch),
      pool_count: Keyword.fetch!(opts, :pool_count),
      connect_timeout: Keyword.fetch!(opts, :connect_timeout),
      receive_timeout: Keyword.fetch!(opts, :receive_timeout),
      stream_idle_timeout: Keyword.fetch!(opts, :stream_idle_timeout)
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

  @doc "The base URL as a string, for logs and messages."
  @spec url(t()) :: String.t()
  def url(%__MODULE__{uri: uri}), do: URI.to_string(uri)

  # Trailing slashes are stripped from the path so joining an endpoint
  # onto it cannot produce a double slash, which the server would not
  # route. A path is otherwise kept, as a prefix for proxied
  # deployments.
  defp normalise_uri!(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and is_binary(host) ->
        reject_extras!(uri)

        # Rebuilt from its parts rather than reused. `URI.parse/1`
        # populates the deprecated `:authority` field and `URI.new/1`
        # does not, so a caller passing a URI and a caller passing the
        # equivalent string would otherwise end up with structs that
        # differ in a field nobody reads.
        %URI{
          scheme: scheme,
          host: host,
          port: uri.port,
          path: normalise_path(uri.path)
        }

      _ ->
        raise ArgumentError,
              "expected :url to be an http or https URL with a host, got: #{inspect(url)}"
    end
  end

  # Dropping these silently would be worse than refusing them: a query
  # string on the base URL is a mistake, and userinfo suggests an
  # expectation of authentication that this API does not have.
  defp reject_extras!(%URI{} = uri) do
    for {label, value} <- [query: uri.query, fragment: uri.fragment, userinfo: uri.userinfo],
        value != nil do
      raise ArgumentError,
            "expected :url to be a base URL, but it has a #{label} " <>
              "(#{inspect(value)}). Endpoint paths are appended by the client."
    end

    :ok
  end

  defp normalise_path(nil), do: nil

  defp normalise_path(path) do
    case String.trim_trailing(path, "/") do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
