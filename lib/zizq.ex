# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq do
  @moduledoc """
  Official Elixir client for the [Zizq](https://zizq.io) job queue.

  Zizq is a fast and durable job queue server built on an embedded
  LSM database — not on Redis, and not on your RDBMS. It supports
  multiple producers and multiple consumers across an entire stack,
  with producers and consumers written in any language.
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
    # Built before the span: a malformed enqueue is the caller's
    # mistake, not a failed request, and building it is what supplies
    # the type and queue the span reports.
    enqueue = Zizq.Enqueue.new!(enqueue)
    wire = Zizq.Enqueue.to_wire(enqueue)
    meta = %{client: name, count: 1, type: enqueue.type, queue: enqueue.queue}

    Zizq.Telemetry.span([:enqueue], meta, fn ->
      result =
        case Zizq.HTTP.request(config, :post, "/jobs", wire) do
          # 200 rather than 201 when the job was a duplicate of one
          # already queued, or folded into an existing batch: nothing
          # was created, and the existing job comes back with
          # `:duplicate` or `:folded` set.
          {:ok, status, job} when status in [200, 201] -> {:ok, Zizq.Job.from_wire(job)}
          {:ok, status, body} -> {:error, Zizq.Error.from_response(status, body)}
          {:error, %Zizq.Error{} = error} -> {:error, error}
        end

      {result, stop_metadata(meta, result)}
    end)
  end

  # `:telemetry.span/3` replaces the start metadata rather than merging
  # into it, so the whole map has to go back, not just the outcome.
  defp stop_metadata(meta, {:ok, _value}), do: Map.put(meta, :outcome, :ok)

  defp stop_metadata(meta, {:error, error}),
    do: Map.merge(meta, %{outcome: :error, error: error})

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

    # One span for the request, not one per job. `:type` and `:queue`
    # are carried as `nil` rather than omitted, so a handler tagging
    # metrics by them sees the same key set as a single enqueue.
    meta = %{client: name, count: length(enqueues), type: nil, queue: nil}

    Zizq.Telemetry.span([:enqueue], meta, fn ->
      result =
        case Zizq.HTTP.request(config, :post, "/jobs/bulk", wire) do
          # 200 rather than 201 when every job was a duplicate or
          # folded into an existing batch, so nothing new was created.
          # Both are success.
          {:ok, status, %{"jobs" => jobs}} when status in [200, 201] ->
            {:ok, Enum.map(jobs, &Zizq.Job.from_wire/1)}

          {:ok, status, body} ->
            {:error, Zizq.Error.from_response(status, body)}

          {:error, %Zizq.Error{} = error} ->
            {:error, error}
        end

      {result, stop_metadata(meta, result)}
    end)
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
        "retry_at" => Zizq.Timestamp.to_ms(Map.get(opts, :retry_at)),
        # Omitted unless true: the server defaults it to false, and
        # sending it needlessly would suggest it were meaningful.
        "kill" => if(Map.get(opts, :kill), do: true)
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    Map.put(optional, "message", message)
  end

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

  @doc """
  Read one job by id.

      Zizq.get_job(job.id, MyApp.Zizq)
      #=> {:ok, %Zizq.Job{status: :completed}}

  Unlike the job returned by `enqueue/2`, this one carries its
  `:payload`.

  A job the server no longer holds is `{:error, %Zizq.Error{reason:
  :not_found}}` — which a completed job becomes as soon as its
  retention expires, immediately by default.
  """
  @spec get_job(Zizq.Job.t() | String.t(), atom()) ::
          {:ok, Zizq.Job.t()} | {:error, Zizq.Error.t()}
  def get_job(job, name) when is_atom(name) do
    config = Config.fetch!(name)

    case Zizq.HTTP.request(config, :get, "/jobs/#{job_id(job)}") do
      {:ok, 200, body} -> {:ok, Zizq.Job.from_wire(body)}
      {:ok, status, body} -> {:error, Zizq.Error.from_response(status, body)}
      {:error, %Zizq.Error{} = error} -> {:error, error}
    end
  end

  @doc """
  Read one job by id, raising on failure.
  """
  @spec get_job!(Zizq.Job.t() | String.t(), atom()) :: Zizq.Job.t()
  def get_job!(job, name) do
    case get_job(job, name) do
      {:ok, job} -> job
      {:error, error} -> raise error
    end
  end

  @doc """
  Change a job that has not finished yet, and return it as it now stands.

      Zizq.update_job(job, MyApp.Zizq, queue: "urgent", priority: 0)

  ## Options

  Only the options given are touched; the rest of the job is left
  alone. Passing `nil` **clears** a field to the server's default,
  which is why an option must be omitted rather than set to `nil` to
  leave it as it is:

      # Retry with the server's default limit, whatever it now is.
      Zizq.update_job(job, MyApp.Zizq, retry_limit: nil)

    * `:queue` — move the job to another queue. Cannot be `nil`.
    * `:priority` — lower runs sooner. Cannot be `nil`.
    * `:ready_at` — a `DateTime` or Unix milliseconds. `nil` makes the
      job ready immediately.
    * `:retry_limit` — `nil` restores the server default.
    * `:backoff` — a `Zizq.Backoff` or keyword list. `nil` restores the
      server default.
    * `:retention` — a `Zizq.Retention` or keyword list, merged field
      by field, so `retention: [completed: :timer.hours(1)]` leaves
      `:dead` alone. `nil` clears the whole override.

  Only jobs that have not finished can be changed: the server rejects
  a completed or dead job with `%Zizq.Error{reason: :invalid_request}`.
  """
  @spec update_job(Zizq.Job.t() | String.t(), atom(), keyword()) ::
          {:ok, Zizq.Job.t()} | {:error, Zizq.Error.t()}
  def update_job(job, name, opts) when is_atom(name) do
    config = Config.fetch!(name)
    wire = patch_body(opts)

    case Zizq.HTTP.request(config, :patch, "/jobs/#{job_id(job)}", wire) do
      {:ok, 200, body} -> {:ok, Zizq.Job.from_wire(body)}
      {:ok, status, body} -> {:error, Zizq.Error.from_response(status, body)}
      {:error, %Zizq.Error{} = error} -> {:error, error}
    end
  end

  @doc """
  Change a job, raising on failure.
  """
  @spec update_job!(Zizq.Job.t() | String.t(), atom(), keyword()) :: Zizq.Job.t()
  def update_job!(job, name, opts) do
    case update_job(job, name, opts) do
      {:ok, job} -> job
      {:error, error} -> raise error
    end
  end

  @patch_keys [:queue, :priority, :ready_at, :retry_limit, :backoff, :retention]
  @patch_non_nullable [:queue, :priority]

  # Absent, `nil` and a value are three different instructions here —
  # leave alone, clear to the server's default, and set — so this maps
  # them onto JSON merge patch rather than compacting `nil` away as
  # `Zizq.Enqueue.to_wire/1` does.
  defp patch_body(opts) do
    opts = Map.new(opts)

    case Map.keys(opts) -- @patch_keys do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown update key#{if length(unknown) > 1, do: "s"}: #{inspect(unknown)}. " <>
                "Known keys are #{inspect(@patch_keys)}"
    end

    if opts == %{} do
      raise ArgumentError, "update_job/3 needs at least one field to change"
    end

    # Rejected here rather than by the server, which answers 422 with
    # the same complaint after a round trip.
    Enum.each(@patch_non_nullable, fn key ->
      if Map.get(opts, key, :absent) == nil do
        raise ArgumentError,
              "update :#{key} cannot be nil — it has no server default to clear to. " <>
                "Omit it to leave the job's #{key} unchanged."
      end
    end)

    Map.new(opts, fn {key, value} -> {Atom.to_string(key), patch_value(key, value)} end)
  end

  defp patch_value(_key, nil), do: nil
  defp patch_value(:ready_at, value), do: Zizq.Timestamp.to_ms(value)
  defp patch_value(:backoff, value), do: value |> Zizq.Backoff.new!() |> Zizq.Backoff.to_wire()

  defp patch_value(:retention, value),
    do: value |> Zizq.Retention.new!() |> Zizq.Retention.to_wire()

  defp patch_value(_key, value), do: value

  @doc """
  List jobs, oldest first, one page at a time.

  Narrow with any of the filters in `Zizq.Filter`:

      Zizq.list_jobs([queue: "emails", status: [:ready]], MyApp.Zizq)
      #=> {:ok, %Zizq.JobPage{jobs: [%Zizq.Job{}, ...]}}

  ## Options

  Every option `Zizq.Filter` documents, plus:

    * `:limit` — jobs per page, 1 to 2000. The server decides if
      unset.
    * `:order` — `:asc` (oldest first) or `:desc` (newest first).
      The server defaults to `:asc`.

  Follow the pages with `next_page/2` and `prev_page/2`.
  """
  @spec list_jobs(keyword(), atom()) :: {:ok, Zizq.JobPage.t()} | {:error, Zizq.Error.t()}
  def list_jobs(opts \\ [], name) when is_atom(name) do
    {page_opts, filters} = Keyword.split(opts, [:limit, :order])
    params = Zizq.Filter.to_params(filters) ++ page_params(page_opts)

    get_page(name, "/jobs?" <> URI.encode_query(params), Zizq.JobPage)
  end

  @doc """
  List jobs, raising on failure.
  """
  @spec list_jobs!(keyword(), atom()) :: Zizq.JobPage.t()
  def list_jobs!(opts \\ [], name) do
    case list_jobs(opts, name) do
      {:ok, page} -> page
      {:error, error} -> raise error
    end
  end

  @doc """
  Fetch the page after this one, or `nil` at the end of the listing.

      {:ok, page} = Zizq.list_jobs([queue: "emails"], MyApp.Zizq)
      {:ok, next} = Zizq.next_page(page, MyApp.Zizq)

  The link carries the cursor and the original filters.
  """
  @spec next_page(page, atom()) :: {:ok, page | nil} | {:error, Zizq.Error.t()}
        when page: Zizq.JobPage.t() | Zizq.ErrorPage.t()
  def next_page(%Zizq.JobPage{next: nil}, name) when is_atom(name), do: {:ok, nil}

  def next_page(%Zizq.JobPage{next: next}, name) when is_atom(name),
    do: get_page(name, next, Zizq.JobPage)

  def next_page(%Zizq.ErrorPage{next: nil}, name) when is_atom(name), do: {:ok, nil}

  def next_page(%Zizq.ErrorPage{next: next}, name) when is_atom(name),
    do: get_page(name, next, Zizq.ErrorPage)

  @doc """
  Fetch the page before this one, or `nil` at the start of the listing.

      {:ok, prev} = Zizq.prev_page(page, MyApp.Zizq)
  """
  @spec prev_page(page, atom()) :: {:ok, page | nil} | {:error, Zizq.Error.t()}
        when page: Zizq.JobPage.t() | Zizq.ErrorPage.t()
  def prev_page(%Zizq.JobPage{prev: nil}, name) when is_atom(name), do: {:ok, nil}

  def prev_page(%Zizq.JobPage{prev: prev}, name) when is_atom(name),
    do: get_page(name, prev, Zizq.JobPage)

  def prev_page(%Zizq.ErrorPage{prev: nil}, name) when is_atom(name), do: {:ok, nil}

  def prev_page(%Zizq.ErrorPage{prev: prev}, name) when is_atom(name),
    do: get_page(name, prev, Zizq.ErrorPage)

  # Takes the page module rather than assuming jobs: error listings
  # paginate through the identical `{items, pages}` shape, so they
  # differ only in how a page decodes. `next_page/2` and `prev_page/2`
  # gain a clause each when those land, not a second implementation.
  defp get_page(name, path, page_module) do
    config = Config.fetch!(name)

    case Zizq.HTTP.request(config, :get, path) do
      {:ok, 200, body} -> {:ok, page_module.from_wire(body)}
      {:ok, status, body} -> {:error, Zizq.Error.from_response(status, body)}
      {:error, %Zizq.Error{} = error} -> {:error, error}
    end
  end

  defp page_params(opts) do
    opts
    |> Enum.map(fn
      {:limit, limit} when is_integer(limit) and limit > 0 ->
        {:limit, limit}

      {:limit, other} ->
        raise ArgumentError, "list :limit must be a positive integer, got #{inspect(other)}"

      {:order, order} when order in [:asc, :desc] ->
        {:order, Atom.to_string(order)}

      {:order, other} ->
        raise ArgumentError, "list :order must be :asc or :desc, got #{inspect(other)}"
    end)
  end

  @doc """
  Start a composable query.

      Zizq.query(MyApp.Zizq)
      |> Zizq.Query.where(queue: "emails", status: [:ready])
      |> Enum.take(10)

  Builds nothing and sends nothing until the query is run. See
  `Zizq.Query`.
  """
  @spec query(atom()) :: Zizq.Query.t()
  def query(name) when is_atom(name), do: Zizq.Query.new(name)

  @doc """
  Count the jobs matching a set of filters.

      Zizq.count_jobs([queue: "emails", status: [:ready]], MyApp.Zizq)
      #=> {:ok, 1_284}

  Counting is a separate endpoint rather than the length of a listing,
  so a count costs one request whatever the total.
  """
  @spec count_jobs(keyword(), atom()) :: {:ok, non_neg_integer()} | {:error, Zizq.Error.t()}
  def count_jobs(filters \\ [], name) when is_atom(name) do
    config = Config.fetch!(name)
    params = URI.encode_query(Zizq.Filter.to_params(filters))

    case Zizq.HTTP.request(config, :get, "/jobs/count?" <> params) do
      {:ok, 200, %{"count" => count}} -> {:ok, count}
      {:ok, status, body} -> {:error, Zizq.Error.from_response(status, body)}
      {:error, %Zizq.Error{} = error} -> {:error, error}
    end
  end

  @doc """
  Count jobs, raising on failure.
  """
  @spec count_jobs!(keyword(), atom()) :: non_neg_integer()
  def count_jobs!(filters \\ [], name) do
    case count_jobs(filters, name) do
      {:ok, count} -> count
      {:error, error} -> raise error
    end
  end

  @doc """
  List the queues the server currently holds jobs for.

      Zizq.list_queues(MyApp.Zizq)
      #=> {:ok, ["default", "emails"]}

  Queues are not declared — one exists because a job named it — so
  this reports what is there rather than what was configured.
  """
  @spec list_queues(atom()) :: {:ok, [String.t()]} | {:error, Zizq.Error.t()}
  def list_queues(name) when is_atom(name) do
    config = Config.fetch!(name)

    case Zizq.HTTP.request(config, :get, "/queues") do
      {:ok, 200, %{"queues" => queues}} -> {:ok, queues}
      {:ok, status, body} -> {:error, Zizq.Error.from_response(status, body)}
      {:error, %Zizq.Error{} = error} -> {:error, error}
    end
  end

  @doc """
  List queues, raising on failure.
  """
  @spec list_queues!(atom()) :: [String.t()]
  def list_queues!(name) do
    case list_queues(name) do
      {:ok, queues} -> queues
      {:error, error} -> raise error
    end
  end

  @doc """
  Change every job matching a set of filters, and return how many.

      Zizq.update_all_jobs(
        [where: [queue: "emails", status: :scheduled], apply: [ready_at: nil]],
        MyApp.Zizq
      )
      #=> {:ok, 42}

  ## Options

    * `:where` — which jobs to change, using the filters in
      `Zizq.Filter`. Restricts the operation the way a `WHERE` clause
      does, and is optional for the same reason: left out, every job
      is changed, deliberately.
    * `:apply` — what to change, using the options `update_job/3`
      takes, with the same merge-patch rules. An omitted option leaves
      a field alone, `nil` clears it. Required.

  Named rather than positional because both halves are keyword lists
  of overlapping keys — `queue:` and `priority:` mean something on
  each side — so transposing them could quietly change the wrong jobs
  rather than fail.

  Finished jobs cannot be changed, so asking for one is an error
  rather than a silent no-op: `status: :completed` or `status: :dead`
  in `:where` is rejected before the request is sent.
  """
  @spec update_all_jobs(keyword(), atom()) ::
          {:ok, non_neg_integer()} | {:error, Zizq.Error.t()}
  def update_all_jobs(opts, name) when is_atom(name) do
    config = Config.fetch!(name)
    {where, changes} = split_bulk_opts!(opts)

    reject_terminal_statuses!(where, "change")
    wire = patch_body(changes)
    params = URI.encode_query(Zizq.Filter.to_params(where))

    case Zizq.HTTP.request(config, :patch, "/jobs?" <> params, wire) do
      {:ok, 200, %{"patched" => count}} -> {:ok, count}
      {:ok, status, body} -> {:error, Zizq.Error.from_response(status, body)}
      {:error, %Zizq.Error{} = error} -> {:error, error}
    end
  end

  @doc """
  Change every matching job, raising on failure.
  """
  @spec update_all_jobs!(keyword(), atom()) :: non_neg_integer()
  def update_all_jobs!(opts, name) do
    case update_all_jobs(opts, name) do
      {:ok, count} -> count
      {:error, error} -> raise error
    end
  end

  defp split_bulk_opts!(opts) do
    case Keyword.keys(opts) -- [:where, :apply] do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "update_all_jobs/2 takes :where and :apply, got #{inspect(unknown)}. " <>
                "Filters go in :where, changes in :apply."
    end

    unless Keyword.has_key?(opts, :apply) do
      raise ArgumentError,
            "update_all_jobs/2 needs :apply — the fields to change. " <>
              "Pass :where to narrow which jobs are changed."
    end

    {Keyword.get(opts, :where, []), Keyword.fetch!(opts, :apply)}
  end

  @doc """
  Delete every job matching a set of filters, and return how many.

      Zizq.delete_all_jobs([queue: "emails", status: :dead], MyApp.Zizq)
      #=> {:ok, 17}

  Selection uses the filters in `Zizq.Filter`.

  Filters restrict what is deleted the way a `WHERE` clause does, and
  are optional for the same reason: `delete_all_jobs([], client)`
  empties the server, deliberately.

  Counting first with the same filters is a cheap way to see what
  would go:

      filters = [queue: "emails", status: :dead]
      {:ok, 17} = Zizq.count_jobs(filters, MyApp.Zizq)
      {:ok, 17} = Zizq.delete_all_jobs(filters, MyApp.Zizq)
  """
  @spec delete_all_jobs(keyword(), atom()) ::
          {:ok, non_neg_integer()} | {:error, Zizq.Error.t()}
  def delete_all_jobs(filters \\ [], name) when is_atom(name) do
    config = Config.fetch!(name)
    params = URI.encode_query(Zizq.Filter.to_params(filters))

    case Zizq.HTTP.request(config, :delete, "/jobs?" <> params) do
      {:ok, 200, %{"deleted" => count}} -> {:ok, count}
      {:ok, status, body} -> {:error, Zizq.Error.from_response(status, body)}
      {:error, %Zizq.Error{} = error} -> {:error, error}
    end
  end

  @doc """
  Delete every matching job, raising on failure.
  """
  @spec delete_all_jobs!(keyword(), atom()) :: non_neg_integer()
  def delete_all_jobs!(filters \\ [], name) do
    case delete_all_jobs(filters, name) do
      {:ok, count} -> count
      {:error, error} -> raise error
    end
  end

  @terminal_statuses [:completed, :dead]

  # Pre-empted rather than left to the server's 422, which costs a
  # round trip to learn something knowable here — and reads as a
  # server complaint about a mistake made at the call site.
  defp reject_terminal_statuses!(filters, verb) do
    filters
    |> Keyword.get(:status)
    |> List.wrap()
    |> Enum.filter(&(&1 in @terminal_statuses))
    |> case do
      [] ->
        :ok

      [status | _] ->
        raise ArgumentError,
              "cannot #{verb} jobs with status #{inspect(status)} — a finished job is " <>
                "not editable. Filter by a status that can still run, or delete them."
    end
  end

  @doc """
  List a job's failed attempts, oldest first.

      Zizq.list_errors(job, MyApp.Zizq)
      #=> {:ok, %Zizq.ErrorPage{errors: [%Zizq.ErrorRecord{attempt: 1}, ...]}}

  ## Options

    * `:limit` — records per page, 1 to 200. The server decides if
      unset.
    * `:order` — `:asc` (first attempt first) or `:desc` (most recent
      first). The server defaults to `:asc`.

  Pages follow with `next_page/2`, the same as a job listing.

  Errors live as long as the job does, so a completed job whose
  retention has expired takes its failure history with it.
  """
  @spec list_errors(Zizq.Job.t() | String.t(), atom(), keyword()) ::
          {:ok, Zizq.ErrorPage.t()} | {:error, Zizq.Error.t()}
  def list_errors(job, name, opts \\ []) when is_atom(name) do
    params = URI.encode_query(page_params(opts))

    get_page(name, "/jobs/#{job_id(job)}/errors?" <> params, Zizq.ErrorPage)
  end

  @doc """
  List a job's failed attempts, raising on failure.
  """
  @spec list_errors!(Zizq.Job.t() | String.t(), atom(), keyword()) :: Zizq.ErrorPage.t()
  def list_errors!(job, name, opts \\ []) do
    case list_errors(job, name, opts) do
      {:ok, page} -> page
      {:error, error} -> raise error
    end
  end

  @doc """
  Read what went wrong on one attempt.

      Zizq.get_error(job, 1, MyApp.Zizq)
      #=> {:ok, %Zizq.ErrorRecord{attempt: 1, message: "SMTP timeout"}}

  Attempts count from 1. An attempt that never failed — or never
  happened — is `{:error, %Zizq.Error{reason: :not_found}}`.
  """
  @spec get_error(Zizq.Job.t() | String.t(), pos_integer(), atom()) ::
          {:ok, Zizq.ErrorRecord.t()} | {:error, Zizq.Error.t()}
  def get_error(job, attempt, name) when is_integer(attempt) and is_atom(name) do
    config = Config.fetch!(name)

    case Zizq.HTTP.request(config, :get, "/jobs/#{job_id(job)}/errors/#{attempt}") do
      {:ok, 200, body} -> {:ok, Zizq.ErrorRecord.from_wire(body)}
      {:ok, status, body} -> {:error, Zizq.Error.from_response(status, body)}
      {:error, %Zizq.Error{} = error} -> {:error, error}
    end
  end

  @doc """
  Read one attempt's error, raising on failure.
  """
  @spec get_error!(Zizq.Job.t() | String.t(), pos_integer(), atom()) :: Zizq.ErrorRecord.t()
  def get_error!(job, attempt, name) do
    case get_error(job, attempt, name) do
      {:ok, record} -> record
      {:error, error} -> raise error
    end
  end

  @doc """
  Install a cron schedule, replacing whatever was there.

  This is the call to make at application startup:

      Zizq.Cron.new("my_app",
        entries: [
          [name: "nightly_cleanup",
           expression: "0 3 * * *",
           job: MyApp.Cleanup.new(%{})],
          [name: "digest",
           expression: "*/15 * * * *",
           timezone: "Australia/Melbourne",
           job: [type: "digest", queue: "reports"]]
        ]
      )
      |> Zizq.replace_cron(MyApp.Zizq)

  Or alternatively pipelined:

      Zizq.Cron.new("my_app")
      |> Zizq.Cron.put_entry(
        name: "nightly_cleanup",
        expression: "0 3 * * *",
        job: MyApp.Cleanup.new(%{})
      )
      |> Zizq.Cron.put_entry(
        name: "digest",
        expression: "*/15 * * * *",
        timezone: "Australia/Melbourne",
        job: [type: "digest", queue: "reports"]
      )
      |> Zizq.replace_cron(MyApp.Zizq)

  It is atomic and idempotent, so every instance of an application can
  run it on boot without coordinating — none of them needs to be the
  one that owns the schedule.

  The group is created if it does not exist, and **entries left out
  are removed**, so a `Zizq.Cron` is the whole schedule rather than an
  addition to it. That is what makes running it on every boot converge
  rather than accumulate.

  Once configured, there is no futher integration required. Your
  `Zizq.Worker` process receives jobs enqueued via the schedule just
  like any other job.

  Cron needs a Pro licence; without one the server answers 403, which
  arrives as `%Zizq.Error{reason: :forbidden}`.
  """
  @spec replace_cron(Zizq.Cron.t(), atom()) :: {:ok, Zizq.Cron.t()} | {:error, Zizq.Error.t()}
  def replace_cron(%Zizq.Cron{} = cron, name) when is_atom(name) do
    config = Config.fetch!(name)

    unless is_binary(cron.name) and cron.name != "" do
      raise ArgumentError,
            "this schedule has no name, so there is nothing to install it as. " <>
              "Build it with Zizq.Cron.new/2."
    end

    case Zizq.HTTP.request(config, :put, cron_path(cron), Zizq.Cron.to_wire(cron)) do
      {:ok, status, body} when status in [200, 201] -> {:ok, Zizq.Cron.from_wire(body)}
      {:ok, status, body} -> {:error, Zizq.Error.from_response(status, body)}
      {:error, %Zizq.Error{} = error} -> {:error, error}
    end
  end

  @doc """
  Install a cron schedule, raising on failure.
  """
  @spec replace_cron!(Zizq.Cron.t(), atom()) :: Zizq.Cron.t()
  def replace_cron!(cron, name) do
    case replace_cron(cron, name) do
      {:ok, group} -> group
      {:error, error} -> raise error
    end
  end

  @doc """
  Read a cron schedule and its entries.
  """
  @spec get_cron(Zizq.Cron.t() | String.t(), atom()) ::
          {:ok, Zizq.Cron.t()} | {:error, Zizq.Error.t()}
  def get_cron(cron, name) when is_atom(name) do
    config = Config.fetch!(name)

    case Zizq.HTTP.request(config, :get, cron_path(cron)) do
      {:ok, 200, body} -> {:ok, Zizq.Cron.from_wire(body)}
      {:ok, status, body} -> {:error, Zizq.Error.from_response(status, body)}
      {:error, %Zizq.Error{} = error} -> {:error, error}
    end
  end

  @doc """
  Read a cron schedule, raising on failure.
  """
  @spec get_cron!(Zizq.Cron.t() | String.t(), atom()) :: Zizq.Cron.t()
  def get_cron!(cron, name) do
    case get_cron(cron, name) do
      {:ok, group} -> group
      {:error, error} -> raise error
    end
  end

  @doc """
  List the names of every cron schedule on the server.
  """
  @spec list_crons(atom()) :: {:ok, [String.t()]} | {:error, Zizq.Error.t()}
  def list_crons(name) when is_atom(name) do
    config = Config.fetch!(name)

    case Zizq.HTTP.request(config, :get, "/crons") do
      {:ok, 200, %{"crons" => crons}} -> {:ok, crons}
      {:ok, status, body} -> {:error, Zizq.Error.from_response(status, body)}
      {:error, %Zizq.Error{} = error} -> {:error, error}
    end
  end

  @doc """
  List cron schedule names, raising on failure.
  """
  @spec list_crons!(atom()) :: [String.t()]
  def list_crons!(name) do
    case list_crons(name) do
      {:ok, crons} -> crons
      {:error, error} -> raise error
    end
  end

  @doc """
  Delete a cron schedule and everything all its entries.

  Jobs it already enqueued are unaffected.
  """
  @spec delete_cron(Zizq.Cron.t() | String.t(), atom()) :: :ok | {:error, Zizq.Error.t()}
  def delete_cron(cron, name) when is_atom(name) do
    config = Config.fetch!(name)

    case Zizq.HTTP.request(config, :delete, cron_path(cron)) do
      {:ok, 204, _body} -> :ok
      {:ok, status, body} -> {:error, Zizq.Error.from_response(status, body)}
      {:error, %Zizq.Error{} = error} -> {:error, error}
    end
  end

  @doc """
  Delete a cron schedule, raising on failure.
  """
  @spec delete_cron!(Zizq.Cron.t() | String.t(), atom()) :: :ok
  def delete_cron!(cron, name) do
    case delete_cron(cron, name) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end

  @doc """
  Delete every cron schedule, and return how many were removed.
  """
  @spec delete_all_crons(atom()) :: {:ok, non_neg_integer()} | {:error, Zizq.Error.t()}
  def delete_all_crons(name) when is_atom(name) do
    config = Config.fetch!(name)

    case Zizq.HTTP.request(config, :delete, "/crons") do
      {:ok, 200, %{"deleted" => count}} -> {:ok, count}
      {:ok, status, body} -> {:error, Zizq.Error.from_response(status, body)}
      {:error, %Zizq.Error{} = error} -> {:error, error}
    end
  end

  @doc """
  Suspend a whole cron schedule. Its entries stop firing until resumed.
  """
  @spec pause_cron(Zizq.Cron.t() | String.t(), atom()) ::
          {:ok, Zizq.Cron.t()} | {:error, Zizq.Error.t()}
  def pause_cron(cron, name), do: set_cron_paused(cron, name, true)

  @doc """
  Resume a suspended cron schedule.
  """
  @spec resume_cron(Zizq.Cron.t() | String.t(), atom()) ::
          {:ok, Zizq.Cron.t()} | {:error, Zizq.Error.t()}
  def resume_cron(cron, name), do: set_cron_paused(cron, name, false)

  defp set_cron_paused(cron, name, paused) when is_atom(name) do
    config = Config.fetch!(name)

    case Zizq.HTTP.request(config, :patch, cron_path(cron), %{"paused" => paused}) do
      {:ok, 200, body} -> {:ok, Zizq.Cron.from_wire(body)}
      {:ok, status, body} -> {:error, Zizq.Error.from_response(status, body)}
      {:error, %Zizq.Error{} = error} -> {:error, error}
    end
  end

  @doc """
  Suspend one cron entry, leaving the rest of its schedule running.

      Zizq.pause_cron_entry([cron: "my_app", entry: "digest"], MyApp.Zizq)

  Changes only that entry, on the server, so it is safe while an
  application is running, unlike reading a schedule, amending it and
  replacing it, which is last-write-wins.

  Named rather than positional for clarity.
  """
  @spec pause_cron_entry(keyword(), atom()) ::
          {:ok, Zizq.CronEntry.t()} | {:error, Zizq.Error.t()}
  def pause_cron_entry(opts, name), do: set_cron_entry_paused(opts, name, true)

  @doc """
  Resume one suspended cron entry.
  """
  @spec resume_cron_entry(keyword(), atom()) ::
          {:ok, Zizq.CronEntry.t()} | {:error, Zizq.Error.t()}
  def resume_cron_entry(opts, name), do: set_cron_entry_paused(opts, name, false)

  defp set_cron_entry_paused(opts, name, paused) when is_atom(name) do
    config = Config.fetch!(name)
    path = cron_entry_path!(opts)

    case Zizq.HTTP.request(config, :patch, path, %{"paused" => paused}) do
      {:ok, 200, body} -> {:ok, Zizq.CronEntry.from_wire(body)}
      {:ok, status, body} -> {:error, Zizq.Error.from_response(status, body)}
      {:error, %Zizq.Error{} = error} -> {:error, error}
    end
  end

  @doc """
  Delete one cron entry, leaving the rest of its schedule alone.

      Zizq.delete_cron_entry([cron: "my_app", entry: "digest"], MyApp.Zizq)

  The server-side counterpart to `Zizq.Cron.delete_entry/2`, which
  changes a schedule in memory you then replace whole on the server.
  """
  @spec delete_cron_entry(keyword(), atom()) :: :ok | {:error, Zizq.Error.t()}
  def delete_cron_entry(opts, name) when is_atom(name) do
    config = Config.fetch!(name)
    path = cron_entry_path!(opts)

    case Zizq.HTTP.request(config, :delete, path) do
      {:ok, 204, _body} -> :ok
      {:ok, status, body} -> {:error, Zizq.Error.from_response(status, body)}
      {:error, %Zizq.Error{} = error} -> {:error, error}
    end
  end

  @doc """
  Delete one cron entry, raising on failure.
  """
  @spec delete_cron_entry!(keyword(), atom()) :: :ok
  def delete_cron_entry!(opts, name) do
    case delete_cron_entry(opts, name) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end

  defp cron_entry_path!(opts) do
    case Keyword.keys(opts) -- [:cron, :entry] do
      [] -> :ok
      unknown -> raise ArgumentError, "takes :cron and :entry, got #{inspect(unknown)}"
    end

    for key <- [:cron, :entry] do
      unless is_binary(Keyword.get(opts, key)) do
        raise ArgumentError, ":#{key} is required, and must be a name"
      end
    end

    "/crons/#{segment(opts[:cron])}/entries/#{segment(opts[:entry])}"
  end

  defp cron_path(%Zizq.Cron{name: name}), do: cron_path(name)

  defp cron_path(name) when is_binary(name), do: "/crons/#{segment(name)}"

  # `URI.encode/1` leaves `/` and `?` alone, which is right for a whole
  # URI and wrong for one segment of one. A cron or entry name is a
  # single segment, and the server permits names holding both.
  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  @doc """
  Delete every job and every cron schedule on the server.

      Zizq.erase_all_data(MyApp.Zizq)
      #=> :ok

  > #### This empties the server {: .warning}
  >
  > Not a filtered delete — there is nothing to narrow and nothing to
  > confirm. Every job in every queue and every schedule goes, and the
  > call simply returns once they have.

  Intended as a setup or teardown step in tests and development, where
  a known-empty server between scenarios is worth more than the data.
  It is one request rather than `delete_all_jobs/2` followed by
  `delete_all_crons/1`.
  """
  @spec erase_all_data(atom()) :: :ok | {:error, Zizq.Error.t()}
  def erase_all_data(name) when is_atom(name) do
    config = Config.fetch!(name)

    case Zizq.HTTP.request(config, :post, "/reset", %{}) do
      {:ok, 204, _body} -> :ok
      {:ok, status, body} -> {:error, Zizq.Error.from_response(status, body)}
      {:error, %Zizq.Error{} = error} -> {:error, error}
    end
  end

  @doc """
  Delete every job and schedule, raising on failure.
  """
  @spec erase_all_data!(atom()) :: :ok
  def erase_all_data!(name) do
    case erase_all_data(name) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end

  @doc """
  Delete a job outright.

      Zizq.delete_job(job, MyApp.Zizq)
      #=> :ok

  Unlike `report_failure/3` with `kill: true`, which leaves a dead job
  behind to be inspected, this removes it. A job the server no longer
  holds is `{:error, %Zizq.Error{reason: :not_found}}`.
  """
  @spec delete_job(Zizq.Job.t() | String.t(), atom()) :: :ok | {:error, Zizq.Error.t()}
  def delete_job(job, name) when is_atom(name) do
    config = Config.fetch!(name)

    case Zizq.HTTP.request(config, :delete, "/jobs/#{job_id(job)}") do
      {:ok, 204, _body} -> :ok
      {:ok, status, body} -> {:error, Zizq.Error.from_response(status, body)}
      {:error, %Zizq.Error{} = error} -> {:error, error}
    end
  end

  @doc """
  Delete a job outright, raising on failure.
  """
  @spec delete_job!(Zizq.Job.t() | String.t(), atom()) :: :ok
  def delete_job!(job, name) do
    case delete_job(job, name) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end
end
