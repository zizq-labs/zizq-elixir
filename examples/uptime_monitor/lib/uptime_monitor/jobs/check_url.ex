defmodule UptimeMonitor.Jobs.CheckUrl do
  @moduledoc """
  Probes one monitored URL and records the result.

  Enqueued when a URL is submitted, and again by the periodic sweep
  once its last check goes stale.
  """

  use Zizq.JobKind,
    type: "uptime_monitor.check_url",
    queue: UptimeMonitor.Jobs.queue(),
    # A probe that fails is usually the site being down, not the job
    # being wrong, and the next sweep will try again anyway — so a
    # short ladder rather than a long one.
    retry_limit: 3,
    backoff: [base: :timer.seconds(5), exponent: 2.0, jitter: :timer.seconds(5)]

  alias UptimeMonitor.Monitors
  alias UptimeMonitor.UrlProber

  @impl Zizq.JobKind
  def perform(%{"id" => id}) when is_integer(id) do
    case Monitors.get_url(id) do
      # Deleted between being enqueued and being run. Nothing to do,
      # and nothing wrong — a sweep enqueues from a snapshot.
      nil ->
        :ok

      %{enabled: false} ->
        :ok

      url ->
        check(url)
    end
  end

  def perform(payload) do
    {:cancel, "expected a payload of %{\"id\" => integer}, got: #{inspect(payload)}"}
  end

  defp check(url) do
    result = UrlProber.probe(url.url)

    case Monitors.record_check(url, result) do
      {:ok, _check} ->
        :ok

      # The probe worked; writing it down did not. Worth retrying,
      # unlike a bad payload.
      {:error, changeset} ->
        {:error, "could not record check: #{inspect(changeset.errors)}"}
    end
  end
end
