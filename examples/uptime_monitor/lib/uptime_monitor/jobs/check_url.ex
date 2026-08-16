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

  require Logger

  alias UptimeMonitor.Audit
  alias UptimeMonitor.Jobs
  alias UptimeMonitor.Jobs.DiscoverSitemapUrls
  alias UptimeMonitor.Jobs.NotifyWebhook
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
    # Read before the check is recorded, since recording is what
    # overwrites it.
    previous_status = url.last_status

    result = UrlProber.probe(url.url)

    case Monitors.record_check(url, result) do
      {:ok, recorded} ->
        if transitioned?(previous_status, result.status) do
          announce(url, recorded, previous_status, result.status)
        end

        maybe_discover_sitemap(url, result)
        :ok

      # The probe worked; writing it down did not. Worth retrying,
      # unlike a bad payload.
      {:error, changeset} ->
        {:error, "could not record check: #{inspect(changeset.errors)}"}
    end
  end

  # A URL is only interesting when it *changes*.
  #
  #   * Same as last time — nothing to say.
  #   * Never checked, and up — a first success is not news.
  #   * Never checked, and down — an outage should be announced at
  #     once rather than waiting for a second sample to compare with.
  #   * Anything else — a genuine transition.
  defp transitioned?(previous, current) when previous == current, do: false
  defp transitioned?(nil, current), do: current == "down"
  defp transitioned?(_previous, _current), do: true

  defp announce(url, recorded, previous_status, current_status) do
    Audit.emit(
      event_type: "url.status.changed",
      resource: "monitored_url:#{url.id}",
      text: "#{url.url} went #{current_status}",
      data: %{
        "url" => url.url,
        "from" => previous_status,
        "to" => current_status
      }
    )

    notify_webhook(url, recorded)
  end

  defp notify_webhook(url, recorded) do
    enqueue = NotifyWebhook.new(%{"check_id" => recorded.id})

    case Zizq.enqueue(enqueue, Jobs.client()) do
      {:ok, _job} ->
        :ok

      # Logged rather than failed, for the same reason as below: the
      # check is recorded, and failing would probe again and write a
      # second one.
      {:error, error} ->
        Logger.warning(
          "[uptime_monitor] #{url.url}: could not enqueue webhook notification " <>
            "(#{Exception.message(error)})"
        )

        :ok
    end
  end

  defp maybe_discover_sitemap(_url, %{sitemap?: false}), do: :ok

  defp maybe_discover_sitemap(url, _result) do
    enqueue = DiscoverSitemapUrls.new(%{"id" => url.id})

    case Zizq.enqueue(enqueue, Jobs.client()) do
      {:ok, _job} ->
        :ok

      # Logged rather than failed. The check is already recorded, so
      # failing would re-probe and write a second one; and the next
      # sweep re-detects the sitemap anyway, so nothing is lost for
      # longer than one interval.
      {:error, error} ->
        Logger.warning(
          "[uptime_monitor] #{url.url}: could not enqueue sitemap discovery " <>
            "(#{Exception.message(error)})"
        )

        :ok
    end
  end
end
