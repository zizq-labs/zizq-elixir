defmodule UptimeMonitor.Jobs.NotifyWebhook do
  @moduledoc """
  Posts a status transition to a configured webhook.

  Enqueued by `UptimeMonitor.Jobs.CheckUrl` when a URL changes state,
  not on every probe — the point is to say *something happened*, not
  to stream every result.

  Retrying is Zizq's to do, so this only decides whether another
  attempt could help: a 5xx or a connection failure is worth retrying,
  a 4xx is the receiver saying no and will say it again.
  """

  use Zizq.JobKind,
    type: "uptime_monitor.notify_webhook",
    queue: UptimeMonitor.Jobs.queue(),
    # Longer than a probe's. A missed probe is picked up by the next
    # sweep; a missed notification is simply lost.
    retry_limit: 5,
    backoff: [base: :timer.seconds(10), exponent: 2.0, jitter: :timer.seconds(15)]

  require Logger

  alias UptimeMonitor.Monitors

  @impl Zizq.JobKind
  def perform(%{"check_id" => id}) when is_integer(id) do
    with url when is_binary(url) <- webhook_url(),
         check when not is_nil(check) <- Monitors.get_check(id),
         monitored when not is_nil(monitored) <- Monitors.get_url(check.monitored_url_id) do
      post(url, body(check, monitored))
    else
      # No webhook configured, or the check or URL was deleted between
      # this job being enqueued and being run. Nothing to do.
      _otherwise -> :ok
    end
  end

  def perform(payload) do
    {:cancel, "expected a payload of %{\"check_id\" => integer}, got: #{inspect(payload)}"}
  end

  defp post(url, body) do
    options =
      [
        url: url,
        method: :post,
        json: body,
        connect_options: [timeout: 5_000],
        receive_timeout: 10_000,
        retry: false
      ] ++ Application.get_env(:uptime_monitor, :req_options, [])

    case Req.request(options) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      # The receiver understood and refused. Another attempt gets the
      # same answer, so this stops rather than spending the ladder.
      {:ok, %Req.Response{status: status}} when status in 400..499 ->
        Logger.warning("[uptime_monitor] webhook returned HTTP #{status}; giving up")
        :ok

      {:ok, %Req.Response{status: status}} ->
        {:error, "webhook returned HTTP #{status}"}

      {:error, exception} ->
        {:error, "webhook request failed: #{Exception.message(exception)}"}
    end
  end

  defp body(check, monitored) do
    %{
      "check_id" => check.id,
      "monitored_url_id" => monitored.id,
      "url" => monitored.url,
      "status" => check.status,
      "http_status" => check.http_status,
      "response_time_ms" => check.response_time_ms,
      "final_url" => check.final_url,
      "error_message" => check.error_message,
      "consecutive_failures" => monitored.consecutive_failures,
      "checked_at" => DateTime.to_iso8601(check.checked_at)
    }
  end

  defp webhook_url do
    case Application.get_env(:uptime_monitor, :webhook_url) do
      url when is_binary(url) -> String.trim(url) |> presence()
      _otherwise -> nil
    end
  end

  defp presence(""), do: nil
  defp presence(url), do: url
end
