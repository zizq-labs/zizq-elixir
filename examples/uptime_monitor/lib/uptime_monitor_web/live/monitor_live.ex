defmodule UptimeMonitorWeb.MonitorLive do
  @moduledoc """
  The monitored-URL dashboard.

  Rows update as probes land, without polling: the worker records a
  check, `UptimeMonitor.Monitors` broadcasts it, and every connected
  browser re-renders. The worker is running jobs in its own processes,
  possibly on another node, and neither knows about the other.
  """

  use UptimeMonitorWeb, :live_view

  alias UptimeMonitor.Audit
  alias UptimeMonitor.Jobs
  alias UptimeMonitor.Jobs.CheckUrl
  alias UptimeMonitor.Monitors
  alias UptimeMonitor.Monitors.MonitoredUrl

  @impl true
  def mount(_params, _session, socket) do
    # Only once connected. The first, static render happens in a
    # throwaway process that would leave a dangling subscription.
    if connected?(socket), do: Monitors.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Uptime Monitor")
     |> assign_form()
     |> assign_urls()}
  end

  @impl true
  def handle_event("add", %{"monitored_url" => params}, socket) do
    case Monitors.create_url(params) do
      {:ok, url} ->
        announce(url)
        check_now(url)

        {:noreply,
         socket
         |> put_flash(:info, "Now monitoring #{url.url}")
         |> assign_form()
         |> assign_urls()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Monitors.get_url(String.to_integer(id)) do
      nil ->
        {:noreply, assign_urls(socket)}

      url ->
        {:ok, _} = Monitors.delete_url(url)

        {:noreply,
         socket
         |> put_flash(:info, "Stopped monitoring #{url.url}")
         |> assign_urls()}
    end
  end

  def handle_event("check", %{"id" => id}, socket) do
    case Monitors.get_url(String.to_integer(id)) do
      nil ->
        {:noreply, assign_urls(socket)}

      url ->
        {:noreply,
         socket |> tap(fn _ -> check_now(url) end) |> put_flash(:info, "Checking #{url.url}…")}
    end
  end

  # Something changed the monitored URLs — a probe landed, a sitemap
  # was reconciled, someone else added one. Which it was does not
  # change what this page renders.
  @impl true
  def handle_info(:urls_changed, socket) do
    {:noreply, assign_urls(socket)}
  end

  defp assign_urls(socket), do: assign(socket, :urls, Monitors.list_urls())

  defp assign_form(socket) do
    assign(socket, :form, to_form(Monitors.change_url(%MonitoredUrl{})))
  end

  # A URL should not have to wait for the next sweep to be checked for
  # the first time.
  defp check_now(url) do
    Zizq.enqueue(CheckUrl.new(%{"id" => url.id}), Jobs.client())
  end

  defp announce(url) do
    Audit.emit(
      event_type: "url.added",
      resource: "monitored_url:#{url.id}",
      text: "Started monitoring #{url.url}",
      data: %{"url" => url.url, "source" => url.source}
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <header>
      <h1>Uptime Monitor</h1>
      <p class="hint">
        Probes run as Zizq jobs on the <code>{Jobs.queue()}</code> queue.
        This page updates as they land.
      </p>
    </header>

    <main>
      <Layouts.flash_group flash={@flash} />

      <.form for={@form} phx-submit="add" class="add-url">
        <input
          type="text"
          name={@form[:url].name}
          value={Phoenix.HTML.Form.normalize_value("text", @form[:url].value)}
          placeholder="https://example.com or a sitemap.xml"
          aria-label="URL to monitor"
        />
        <button type="submit">Monitor</button>
      </.form>

      <p :for={error <- @form[:url].errors} class="error">
        {translate_error(error)}
      </p>

      <p :if={@urls == []} class="empty">Nothing monitored yet.</p>

      <table :if={@urls != []} class="events">
        <thead>
          <tr>
            <th>URL</th>
            <th>Status</th>
            <th>Checked</th>
            <th>Response</th>
            <th>Failures</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={url <- @urls} id={"url-#{url.id}"}>
            <td class="url">
              <a href={url.url} target="_blank" rel="noopener">{url.url}</a>
              <span :if={url.source == "sitemap"} class="sitemap-badge">sitemap</span>
              <span :if={not url.enabled} class="sitemap-badge">disabled</span>
            </td>
            <td>
              <span class={"status status-#{url.last_status || "unknown"}"}>
                {url.last_status || "waiting"}
              </span>
            </td>
            <td class="when">{time_ago(url.last_checked_at)}</td>
            <td class="when">{response_time(url)}</td>
            <td class="failures">{url.consecutive_failures}</td>
            <td class="actions">
              <button phx-click="check" phx-value-id={url.id}>Check now</button>
              <button phx-click="delete" phx-value-id={url.id} data-confirm="Stop monitoring?">
                Remove
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </main>
    """
  end

  defp response_time(url) do
    case Monitors.recent_checks(url, limit: 1) do
      [%{response_time_ms: ms}] when is_integer(ms) -> "#{ms}ms"
      _otherwise -> ""
    end
  end

  defp time_ago(nil), do: "never"

  defp time_ago(%DateTime{} = at) do
    case DateTime.diff(DateTime.utc_now(), at, :second) do
      seconds when seconds < 5 -> "just now"
      seconds when seconds < 60 -> "#{seconds}s ago"
      seconds when seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds when seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      seconds -> "#{div(seconds, 86_400)}d ago"
    end
  end
end
