# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Worker do
  @moduledoc """
  Takes jobs from a queue and runs them.

  Add one to your supervision tree alongside a client:

      children = [
        {Zizq, name: MyApp.Zizq, url: "http://localhost:7890"},
        {Zizq.Worker,
         client: MyApp.Zizq,
         queues: ["emails"],
         concurrency: 25,
         handler: &MyApp.handle_job/1}
      ]

  ## The handler

  A one-argument function receiving a `Zizq.Job`. What it returns
  decides what happens to the job:

  | Returns | Outcome |
  | --- | --- |
  | `:ok` or `{:ok, term}` | acknowledged as complete |
  | `{:error, reason}` | failed; retried per the backoff policy |
  | `{:cancel, reason}` | killed now, whatever retries remain |
  | `{:snooze, milliseconds}` | retried after that long, ignoring backoff |
  | `{:snooze, %DateTime{}}` | retried at that time, ignoring backoff |
  | raises, exits, or is killed | failed, with the exception and stacktrace |

  Snooze durations are **milliseconds**, as every duration in this
  client is, so `{:snooze, :timer.minutes(5)}` says plainly what
  `{:snooze, 300_000}` means. Note that if you are coming from Oban, Oban's
  equivalent is in seconds; take care if porting jobs from Oban to Zizq.

  Anything else is acknowledged as complete and logged as a warning
  naming what was returned. Failing the job instead would be worse —
  the handler most likely did its work and ended on the wrong value, e.g.
  due to a Logger call, so failing would re-run a side effect that already
  happened. Return `:ok` explicitly to keep the log quiet.

  ## Isolation

  Each job runs in its own supervised task. A handler that raises,
  exits, or is killed outright cannot take the worker down — the crash
  is reported to the server as a failure and the next job starts. A
  slow handler cannot block the stream from being read either.

  ## Shutdown

  On shutdown the worker stops taking new work, waits for running jobs
  to finish, flushes outstanding acknowledgements, and only then closes
  the connection — in that order, so the server keeps the in-flight
  jobs until the acknowledgements arrive. Anything still running when
  `:drain_timeout` expires is abandoned and redelivered later.
  """

  use Supervisor

  @options_schema [
    client: [type: :atom, required: true, doc: "Name of a running `Zizq` client."],
    handler: [
      type: {:or, [{:fun, 1}, {:struct, Zizq.Router}]},
      required: true,
      doc: """
      What to run for each job: a function taking a `Zizq.Job`, or a
      `Zizq.Router` to dispatch by type. A router is compiled to a
      function once, when the worker starts.
      """
    ],
    name: [type: :atom, doc: "Name for this worker. Defaults to the module."],
    queues: [
      type: {:list, :string},
      default: [],
      doc: "Queues to take from. Empty means every queue."
    ],
    concurrency: [
      type: :pos_integer,
      default: 10,
      doc: "How many jobs may run at once."
    ],
    prefetch: [
      type: :pos_integer,
      doc: """
      Maximum unacknowledged jobs the server will send. Defaults to
      twice `:concurrency`, so a replacement job is already waiting
      when one finishes rather than costing a round trip.
      """
    ],
    worker_id: [
      type: :string,
      doc: "Identifies this worker in the server's logs. Assigned by the server if omitted."
    ],
    drain_timeout: [
      # Deliberately not `:timeout`: `:infinity` would permit a worker
      # that can never be stopped, defeating the purpose of a shutdown
      # budget (and used to raise, since a deadline is computed by
      # adding this to the clock).
      type: :pos_integer,
      default: 30_000,
      doc: """
      Milliseconds to allow on shutdown for running jobs to finish and
      acknowledgements to be flushed.

      This is the whole budget, not a per-step one: stopping the worker
      will not take materially longer than this, so it can be set from
      whatever deadline a deployment or orchestrator imposes. Jobs
      still running when it expires are abandoned locally, and
      redelivered by the server upon worker disconnection.
      """
    ]
  ]

  @doc """
  Start a new worker.

  ## Options

  #{NimbleOptions.docs(@options_schema)}
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    opts = NimbleOptions.validate!(opts, @options_schema)
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @impl Supervisor
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    tasks = Module.concat(name, Tasks)
    acker = Module.concat(name, Acker)
    concurrency = Keyword.fetch!(opts, :concurrency)
    drain_timeout = Keyword.fetch!(opts, :drain_timeout)

    runner_opts =
      opts
      |> Keyword.take([:client, :handler, :queues, :worker_id])
      |> Keyword.merge(
        acker: acker,
        tasks: tasks,
        worker: name,
        concurrency: concurrency,
        drain_timeout: drain_timeout,
        prefetch: Keyword.get(opts, :prefetch, concurrency * 2)
      )

    children = [
      # Ordered so that shutdown, which runs in reverse, unwinds
      # correctly: the runner stops first and drains while the tasks
      # and the acker it depends on are both still alive.
      {Task.Supervisor, name: tasks},
      {Zizq.Worker.Acker, client: Keyword.fetch!(opts, :client), name: acker},
      Supervisor.child_spec(
        {Zizq.Worker.Runner, runner_opts},
        # Exactly the drain timeout, so that value is the whole
        # shutdown budget and not merely the runner's share of it.
        # Without it the supervisor's 5s default would kill the runner
        # mid-drain; with anything larger, `:drain_timeout` would
        # understate how long stopping can really take, which matters
        # when a deployment is holding a rollout open waiting for it.
        #
        # The runner keeps its own deadline slightly inside this one so
        # it finishes of its own accord rather than being killed.
        shutdown: drain_timeout
      )
    ]

    # `:rest_for_one` so a crashed acker also restarts the runner that
    # holds a reference to it, rather than leaving the runner talking
    # to a dead process.
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
