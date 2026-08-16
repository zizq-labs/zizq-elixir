defmodule UptimeMonitor.Cron do
  @moduledoc """
  Installs this app's schedule on the Zizq server at boot.

  The schedule lives on the server, so re-checks survive a restart and
  nothing here has to hold a timer. Installing is atomic and
  idempotent, so every instance of this app can do it on boot without
  coordinating — none of them needs to be designated the owner.

  What is passed is the **whole** schedule: an entry deleted from this
  module is gone from the server after the next deploy, which is what
  makes running this on every boot converge rather than accumulate.
  """

  require Logger

  alias UptimeMonitor.Jobs
  alias UptimeMonitor.Jobs.ScheduleChecks

  @group "uptime_monitor"

  # Seconds are the optional sixth field. The sweep fires often and
  # `ScheduleChecks` decides what is actually due, so this is a
  # heartbeat rather than the check interval.
  @sweep_expression "*/5 * * * * *"

  @doc """
  The cron group this app owns on the server.
  """
  @spec group() :: String.t()
  def group, do: @group

  @doc """
  Install the schedule, returning what happened.

  Never raises, and never stops the application from starting. Cron is
  a Pro-licensed feature, so a server without a licence answers 403 —
  and this app is still perfectly usable then, just without periodic
  re-checks. A URL submitted by hand is still checked immediately.
  """
  @spec install() :: :ok | {:skipped, atom()}
  def install do
    Zizq.Cron.new(@group, entries: entries())
    |> Zizq.replace_cron(Jobs.client())
    |> case do
      {:ok, _cron} ->
        Logger.info("[uptime_monitor] cron installed: re-checks every #{@sweep_expression}")
        :ok

      {:error, %Zizq.Error{reason: :forbidden}} ->
        Logger.warning(
          "[uptime_monitor] periodic re-checks are disabled: cron needs a Zizq Pro licence. " <>
            "URLs submitted by hand are still checked immediately."
        )

        {:skipped, :forbidden}

      {:error, %Zizq.Error{reason: reason} = error} ->
        Logger.warning("[uptime_monitor] could not install cron: #{Exception.message(error)}")

        {:skipped, reason}
    end
  end

  @doc """
  The entries this app's schedule consists of.
  """
  @spec entries() :: [keyword()]
  def entries do
    [
      [
        name: "schedule_checks",
        expression: @sweep_expression,
        job: ScheduleChecks.new(%{})
      ]
    ]
  end
end
