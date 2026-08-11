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
      # 200 rather than 201 when the job was a duplicate of one already
      # queued, or folded into an existing batch: nothing was created,
      # and the existing job comes back with `:duplicate` or `:folded`
      # set.
      {:ok, status, job} when status in [200, 201] -> {:ok, Zizq.Job.from_wire(job)}
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
  Report a job as completed successfully.

  Accepts a `Zizq.Job` or a job id.

      Zizq.report_success(job, MyApp.Zizq)
      #=> :ok

  A job the server no longer holds in flight — already acknowledged, or
  redelivered elsewhere after its visibility timeout — answers
  `{:error, %Zizq.Error{reason: :not_found}}`. That is usually benign
  rather than a failure: the work is done either way, and nothing is
  gained by retrying.

  > #### Completed jobs disappear by default {: .tip}
  >
  > The server's default retention for completed jobs is zero, so a job
  > is purged as it completes and a later `GET /jobs/{id}` will 404.
  > Set `retention: [completed: ...]` when enqueueing if you need to
  > inspect it afterwards. Dead jobs are kept for seven days by
  > default, so failures remain visible without doing anything.
  """
  @spec report_success(Zizq.Job.t() | String.t(), atom()) :: :ok | {:error, Zizq.Error.t()}
  def report_success(job, name) when is_atom(name) do
    config = Config.fetch!(name)

    case Zizq.HTTP.request(config, :post, "/jobs/#{job_id(job)}/success") do
      {:ok, 204, _body} -> :ok
      {:ok, status, body} -> {:error, Zizq.Error.from_response(status, body)}
      {:error, %Zizq.Error{} = error} -> {:error, error}
    end
  end

  @doc """
  Report many jobs as completed in a single request.

  Returns the ids the server did not recognise, so `{:ok, []}` means
  every one was acknowledged.

      Zizq.report_success_all(jobs, MyApp.Zizq)
      #=> {:ok, []}

  A partial result is a success, not an error: the jobs the server did
  recognise **were** completed. Only the unrecognised ids come back,
  and those are typically jobs already acknowledged or redelivered
  elsewhere. An empty list short-circuits without contacting the server.
  """
  @spec report_success_all([Zizq.Job.t() | String.t()], atom()) ::
          {:ok, [String.t()]} | {:error, Zizq.Error.t()}
  def report_success_all([], name) when is_atom(name), do: {:ok, []}

  def report_success_all(jobs, name) when is_list(jobs) and is_atom(name) do
    config = Config.fetch!(name)
    wire = %{"ids" => Enum.map(jobs, &job_id/1)}

    case Zizq.HTTP.request(config, :post, "/jobs/success", wire) do
      # 204 means every id was found. 422 reports the ones that were
      # not, having completed the rest.
      {:ok, 204, _body} -> {:ok, []}
      {:ok, 422, %{"not_found" => not_found}} -> {:ok, not_found}
      {:ok, status, body} -> {:error, Zizq.Error.from_response(status, body)}
      {:error, %Zizq.Error{} = error} -> {:error, error}
    end
  end

  @doc """
  Report a job as failed.

  The server decides what happens next — reschedule with backoff, or
  declare the job dead once its retry limit is spent — and returns the
  job as it now stands, so the new `:status` and `:attempts` are
  visible immediately.

      Zizq.report_failure(job, MyApp.Zizq, message: "SMTP timeout")

  ## Options

    * `:message` — what went wrong. **Required.**
    * `:error_type` — an exception or error class name, e.g.
      `"Mint.TransportError"`.
    * `:backtrace` — a formatted stacktrace.
    * `:kill` — when true, declare the job dead now regardless of how
      many attempts remain.
    * `:retry_at` — a `t:DateTime.t/0` (or Unix milliseconds) to retry
      at, bypassing the backoff policy. Reschedules the job even if its
      retry limit is spent.

  `:kill` and `:retry_at` are what a handler's `{:cancel, reason}` and
  `{:snooze, milliseconds}` results map onto.
  """
  @spec report_failure(Zizq.Job.t() | String.t(), atom(), keyword()) ::
          {:ok, Zizq.Job.t()} | {:error, Zizq.Error.t()}
  def report_failure(job, name, opts) when is_atom(name) do
    config = Config.fetch!(name)
    wire = failure_body(opts)

    case Zizq.HTTP.request(config, :post, "/jobs/#{job_id(job)}/failure", wire) do
      {:ok, 200, body} -> {:ok, Zizq.Job.from_wire(body)}
      {:ok, status, body} -> {:error, Zizq.Error.from_response(status, body)}
      {:error, %Zizq.Error{} = error} -> {:error, error}
    end
  end

  @failure_keys [:message, :error_type, :backtrace, :kill, :retry_at]

  defp failure_body(opts) do
    opts = Map.new(opts)

    case Map.keys(opts) -- @failure_keys do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown failure #{inspect(unknown)}"
    end

    message = Map.get(opts, :message)

    unless is_binary(message) and message != "" do
      raise ArgumentError,
            "report_failure requires a non-empty :message, got #{inspect(message)}"
    end

    optional =
      %{
        "error_type" => Map.get(opts, :error_type),
        "backtrace" => Map.get(opts, :backtrace),
        "retry_at" => failure_retry_at(Map.get(opts, :retry_at)),
        # Omitted unless true: the server defaults it to false, and
        # sending it needlessly would suggest it were meaningful.
        "kill" => if(Map.get(opts, :kill), do: true)
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    Map.put(optional, "message", message)
  end

  defp failure_retry_at(nil), do: nil
  defp failure_retry_at(%DateTime{} = at), do: DateTime.to_unix(at, :millisecond)
  defp failure_retry_at(ms) when is_integer(ms), do: ms

  defp job_id(%Zizq.Job{id: id}), do: id
  defp job_id(id) when is_binary(id), do: id

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
