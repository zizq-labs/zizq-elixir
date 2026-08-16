defmodule UptimeMonitor.Jobs.DiscoverSitemapUrls do
  @moduledoc """
  Re-fetches a known sitemap, reconciles the URLs it lists, and
  enqueues an immediate check for each.

  Enqueued by `UptimeMonitor.Jobs.CheckUrl` whenever a probe comes
  back flagged as a sitemap, so a sitemap that gains or loses entries
  is picked up on the next sweep without anyone re-submitting it.
  """

  use Zizq.JobKind,
    type: "uptime_monitor.discover_sitemap_urls",
    queue: UptimeMonitor.Jobs.queue(),
    retry_limit: 3,
    backoff: [base: :timer.seconds(10), exponent: 2.0, jitter: :timer.seconds(10)]

  require Logger

  alias UptimeMonitor.Jobs
  alias UptimeMonitor.Jobs.CheckUrl
  alias UptimeMonitor.Monitors
  alias UptimeMonitor.Sitemap

  # One request per batch rather than one per URL. A sitemap of 50,000
  # entries is 100 requests, not 50,000.
  @batch_size 500

  @impl Zizq.JobKind
  def perform(%{"id" => id}) when is_integer(id) do
    case Monitors.get_url(id) do
      nil -> :ok
      sitemap -> discover(sitemap)
    end
  end

  def perform(payload) do
    {:cancel, "expected a payload of %{\"id\" => integer}, got: #{inspect(payload)}"}
  end

  defp discover(sitemap) do
    with {:ok, body} <- fetch(sitemap.url),
         {:ok, urls} <- parse(sitemap.url, body) do
      {created, enabled, disabled} = Monitors.reconcile_sitemap_children(sitemap.url, urls)

      Logger.info(
        "[uptime_monitor] #{sitemap.url}: #{length(urls)} URL(s) listed " <>
          "(#{created} new, #{enabled} re-enabled, #{disabled} disabled)"
      )

      enqueue_checks(sitemap.url)
    else
      # Nothing to do, and nothing wrong: the reason was logged where
      # it was found, and the children were left alone.
      :skip -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_options(url) do
    [
      url: url,
      redirect: true,
      max_redirects: 5,
      connect_options: [timeout: 5_000],
      # A sitemap can be large, so it gets longer to arrive than an
      # ordinary probe does.
      receive_timeout: 30_000,
      retry: false,
      decode_body: false
    ] ++ Application.get_env(:uptime_monitor, :req_options, [])
  end

  defp fetch(url) do
    case Req.get(request_options(url)) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      # Transient as far as this job knows, so it is worth another
      # attempt. `CheckUrl` separately records the URL as down.
      {:ok, %Req.Response{status: status}} when status >= 500 ->
        {:error, "sitemap fetch failed: HTTP #{status}"}

      # A 404 or 403 will say the same thing on every attempt. Failing
      # would burn the retry ladder to reach the same conclusion.
      {:ok, %Req.Response{status: status}} ->
        Logger.warning("[uptime_monitor] #{url}: sitemap fetch returned HTTP #{status}")
        :skip

      {:error, exception} ->
        {:error, "sitemap fetch failed: #{Exception.message(exception)}"}
    end
  end

  # A sitemap that will not parse leaves the children exactly as they
  # were — the alternative is reading a truncated download as "this
  # sitemap is now empty" and disabling every URL in it.
  #
  # Succeeds rather than fails. Discovery runs once per sweep, so a
  # permanently malformed sitemap would otherwise mint a dead job
  # every sweep, for ever, to say the same thing each time.
  defp parse(url, body) do
    case Sitemap.parse(body) do
      {:ok, urls} ->
        {:ok, urls}

      {:error, {:malformed, message}} ->
        Logger.warning("[uptime_monitor] #{url}: sitemap did not parse (#{message})")
        :skip

      {:error, {:not_a_sitemap, root}} ->
        Logger.warning("[uptime_monitor] #{url}: expected a sitemap, got <#{root}>")
        :skip
    end
  end

  defp enqueue_checks(sitemap_url) do
    sitemap_url
    |> Monitors.sitemap_child_ids()
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
