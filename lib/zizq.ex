# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq do
  @moduledoc """
  Official Elixir client for the [Zizq](https://zizq.io) job queue.

  Zizq is a fast and durable job queue server built on an embedded
  LSM database — not on Redis, and not on your RDBMS. It supports
  multiple producers and multiple consumers across an entire stack,
  with producers and consumers written in any language.

  > #### Work in progress {: .warning}
  >
  > This client is under active development and does not yet implement
  > the API.
  """

  # Read at compile time rather than via `Application.spec/2` at
  # runtime: `Mix.Project.config/0` resolves to this project's own
  # config while the package compiles (including when it compiles as
  # somebody else's dependency), and Mix is not available at runtime
  # inside a release.
  @version Mix.Project.config()[:version]

  use Supervisor

  alias Zizq.Config

  @doc """
  Start a client and add it to your supervision tree.

      children = [
        {Zizq, name: MyApp.Zizq, url: "http://localhost:7890"}
      ]

  The `:name` both names the supervisor and is the handle you pass to
  every other function in this module. Several clients can run side by
  side under different names.

  ## Options

  #{NimbleOptions.docs(Zizq.Config.schema())}
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    config = Config.new!(opts)
    Supervisor.start_link(__MODULE__, config, name: config.name)
  end

  # Identify the child by its `:name` rather than by this module, so
  # two clients can sit side by side in one supervision tree without
  # the caller having to wrap either in `Supervisor.child_spec/2` to
  # break an id collision.
  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @impl Supervisor
  def init(%Config{} = config) do
    children = [
      # First, so it terminates last and the config stays readable
      # while Finch shuts down.
      {Zizq.Config.Owner, config},
      {Finch, name: config.finch_name, pools: %{default: pool_opts(config)}}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # `protocols: [:http2]` exactly.
  #
  # Mint speaks HTTP/2 over cleartext (h2c, prior knowledge) only when
  # `:protocols` names http2 *alone*: `Mint.Negotiate.connect/4`
  # dispatches `[:http2]` straight to `HTTP2.connect/4` with whatever
  # scheme it was given, while the combined `[:http1, :http2]` falls
  # through to an HTTP/1 downgrade for `:http` URLs. Finch passes the
  # option through and picks `Finch.HTTP2.Pool` whenever `:http1` is
  # absent.
  #
  # Adding `:http1` here would silently cost every request its
  # multiplexing, with no error to say so.
  #
  # The pool is keyed `:default` rather than by origin on purpose: this
  # Finch instance is private to this client, so everything it sends
  # goes to the configured server, and a key that failed to match the
  # request URL would fall back to Finch's own `[:http1]` default —
  # reintroducing the same silent downgrade.
  defp pool_opts(%Config{} = config) do
    [
      protocols: [:http2],
      count: config.pool_count,
      conn_opts: [transport_opts: [timeout: config.connect_timeout]]
    ]
  end

  @doc """
  Returns the version of this client as a string.

  ## Examples

      iex> Zizq.version()
      "#{@version}"

  """
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  Ask the server for its version.

  Useful as a liveness check — it is the cheapest endpoint the server
  exposes that proves the connection works end to end.

      Zizq.server_version(MyApp.Zizq)
      #=> {:ok, "0.6.1"}

  """
  @spec server_version(atom()) :: {:ok, String.t()} | {:error, Zizq.Error.t()}
  def server_version(name) when is_atom(name) do
    config = Config.fetch!(name)

    case Zizq.HTTP.request(config, :get, "/version") do
      {:ok, 200, %{"version" => version}} -> {:ok, version}
      {:ok, status, body} -> {:error, Zizq.Error.from_response(status, body)}
      {:error, %Zizq.Error{} = error} -> {:error, error}
    end
  end
end
