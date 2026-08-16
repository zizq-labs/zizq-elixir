defmodule UptimeMonitor.Jobs.ScheduleChecks do
  @moduledoc """
  Sweeps for URLs due a re-check and enqueues one each.

  Fired by a cron entry on the server rather than by anything running
  here, so re-checks continue across restarts and no instance of this
  app has to be the one that owns the timer.

  The entry fires often and this job decides what is actually due, so
  the check interval is `@stale_after` rather than the cron
  expression. Moving the interval is a change here, not a change to a
  schedule installed on a server.
  """

  use Zizq.JobKind,
    type: "uptime_monitor.schedule_checks",
    queue: UptimeMonitor.Jobs.queue(),
    # Another sweep is along in a few seconds, so a failed one is not
    # worth chasing.
    retry_limit: 1

  alias UptimeMonitor.Jobs
  alias UptimeMonitor.Jobs.CheckUrl
  alias UptimeMonitor.Monitors

  @stale_after :timer.minutes(1)
  @batch_size 500

  @doc """
  How long a check stays fresh before its URL is swept again.
  """
  @spec stale_after() :: pos_integer()
  def stale_after, do: @stale_after

  @impl Zizq.JobKind
  def perform(_payload) do
    @stale_after
    |> Monitors.stale_url_ids()
    |> enqueue_checks()
  end

  defp enqueue_checks([]), do: :ok

  defp enqueue_checks(ids) do
    ids
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce_while(:ok, fn batch, :ok ->
      batch
      |> Enum.map(&CheckUrl.new(%{"id" => &1}))
      |> Zizq.enqueue_all(Jobs.client())
      |> case do
        {:ok, _jobs} ->
          {:cont, :ok}

        {:error, error} ->
          {:halt, {:error, "could not enqueue checks: #{Exception.message(error)}"}}
      end
    end)
  end
end
