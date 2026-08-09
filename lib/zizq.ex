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
  Enqueue a job.

  Accepts a `Zizq.Enqueue` struct, or a keyword list or map of the same
  fields. Only `:type` is required; see `Zizq.Enqueue` for the rest.

      Zizq.Enqueue.new!(type: "send_email", payload: %{"user_id" => 42})
      |> Zizq.enqueue(MyApp.Zizq)
      #=> {:ok, %Zizq.Job{id: "03gn…", status: :ready}}

  The job comes first and the client second so that enqueues pipe,
  which is how they are normally written once job modules are building
  them.

  Returns the job the server recorded, so its `:id` and server-assigned
  defaults are available immediately. Note that the returned job carries
  no `:payload` — the server omits it from enqueue responses.

  Raises `ArgumentError` for an invalid enqueue, since that is a bug in
  the calling code rather than a runtime condition to handle.
  """
  @spec enqueue(Zizq.Enqueue.t() | keyword() | map(), atom()) ::
          {:ok, Zizq.Job.t()} | {:error, Zizq.Error.t()}
  def enqueue(enqueue, name) when is_atom(name) do
    config = Config.fetch!(name)
    wire = enqueue |> Zizq.Enqueue.new!() |> Zizq.Enqueue.to_wire()

    case Zizq.HTTP.request(config, :post, "/jobs", wire) do
      {:ok, 201, job} -> {:ok, Zizq.Job.from_wire(job)}
      {:ok, status, body} -> {:error, Zizq.Error.from_response(status, body)}
      {:error, %Zizq.Error{} = error} -> {:error, error}
    end
  end

  @doc """
  Enqueue a job, raising on failure.

  Suits call sites where a failed enqueue should abort the surrounding
  work, such as inside a transaction.
  """
  @spec enqueue!(Zizq.Enqueue.t() | keyword() | map(), atom()) :: Zizq.Job.t()
  def enqueue!(enqueue, name) do
    case enqueue(enqueue, name) do
      {:ok, job} -> job
      {:error, error} -> raise error
    end
  end

  @doc """
  Enqueue many jobs in a single atomic bulk request.

  Each element may be a `Zizq.Enqueue` struct, a keyword list, or a
  map, exactly as `enqueue/2` accepts.

      users
      |> Enum.map(&Zizq.Enqueue.new!(type: "send_email", payload: %{"user_id" => &1.id}))
      |> Zizq.enqueue_all(MyApp.Zizq)
      #=> {:ok, [%Zizq.Job{}, ...]}

  Jobs are returned in the order they were sent. An empty list short
  circuits immediately without contacting the server.

  Note that the returned jobs carry no `:payload` — the server omits it
  from enqueue responses.
  """
  @spec enqueue_all([Zizq.Enqueue.t() | keyword() | map()], atom()) ::
          {:ok, [Zizq.Job.t()]} | {:error, Zizq.Error.t()}
  def enqueue_all([], name) when is_atom(name), do: {:ok, []}

  def enqueue_all(enqueues, name) when is_list(enqueues) and is_atom(name) do
    config = Config.fetch!(name)
    wire = %{"jobs" => Enum.map(Enum.with_index(enqueues), &to_wire_at/1)}

    case Zizq.HTTP.request(config, :post, "/jobs/bulk", wire) do
      # 200 rather than 201 when every job was a duplicate or folded
      # into an existing batch, so nothing new was created. Both are
      # success.
      {:ok, status, %{"jobs" => jobs}} when status in [200, 201] ->
        {:ok, Enum.map(jobs, &Zizq.Job.from_wire/1)}

      {:ok, status, body} ->
        {:error, Zizq.Error.from_response(status, body)}

      {:error, %Zizq.Error{} = error} ->
        {:error, error}
    end
  end

  @doc """
  Bulk enqueue many jobs atomically, raising on failure.
  """
  @spec enqueue_all!([Zizq.Enqueue.t() | keyword() | map()], atom()) :: [Zizq.Job.t()]
  def enqueue_all!(enqueues, name) do
    case enqueue_all(enqueues, name) do
      {:ok, jobs} -> jobs
      {:error, error} -> raise error
    end
  end

  defp to_wire_at({enqueue, index}) do
    Zizq.Enqueue.new!(enqueue) |> Zizq.Enqueue.to_wire()
  rescue
    error in ArgumentError ->
      reraise ArgumentError, "jobs[#{index}]: " <> Exception.message(error), __STACKTRACE__
  end

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
