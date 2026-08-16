defmodule UptimeMonitorWeb.MonitorLiveTest do
  use UptimeMonitorWeb.ConnCase

  use Zizq.Testing, client: UptimeMonitor.Zizq

  import Phoenix.LiveViewTest

  alias UptimeMonitor.Audit
  alias UptimeMonitor.Jobs.CheckUrl
  alias UptimeMonitor.Monitors
  alias UptimeMonitor.Monitors.CheckResult

  defp url_fixture(attrs \\ %{}) do
    {:ok, url} =
      attrs
      |> Enum.into(%{url: "https://example.com/#{System.unique_integer([:positive])}"})
      |> Monitors.create_url()

    url
  end

  describe "the dashboard" do
    test "shows an empty state", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/")

      assert html =~ "Nothing monitored yet."
    end

    test "lists monitored URLs", %{conn: conn} do
      url_fixture(%{url: "https://example.com/one"})

      {:ok, _live, html} = live(conn, ~p"/")

      assert html =~ "https://example.com/one"
      refute html =~ "Nothing monitored yet."
    end

    test "shows a URL never checked as waiting", %{conn: conn} do
      url_fixture()

      {:ok, _live, html} = live(conn, ~p"/")

      assert html =~ "waiting"
      assert html =~ "never"
    end

    test "shows the recorded status and failure count", %{conn: conn} do
      url = url_fixture()
      {:ok, _} = Monitors.record_check(url, CheckResult.down(http_status: 500))

      {:ok, _live, html} = live(conn, ~p"/")

      assert html =~ "status-down"
      assert html =~ "down"
    end

    test "marks sitemap-sourced URLs", %{conn: conn} do
      url_fixture(%{
        url: "https://example.com/page",
        source: "sitemap",
        source_sitemap_url: "https://example.com/sitemap.xml"
      })

      {:ok, _live, html} = live(conn, ~p"/")

      assert html =~ "sitemap"
    end
  end

  describe "adding a URL" do
    test "starts monitoring it", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/")

      html =
        live
        |> form("form", %{"monitored_url" => %{"url" => "https://example.com/new"}})
        |> render_submit()

      assert html =~ "https://example.com/new"
      assert Monitors.find_url("https://example.com/new")
    end

    # A new URL should not have to wait for the next sweep.
    test "enqueues an immediate check", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/")

      live
      |> form("form", %{"monitored_url" => %{"url" => "https://example.com/new"}})
      |> render_submit()

      url = Monitors.find_url("https://example.com/new")
      assert_enqueued(type: CheckUrl.type(), payload: %{"id" => url.id})
    end

    test "records an audit event", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/")

      live
      |> form("form", %{"monitored_url" => %{"url" => "https://example.com/new"}})
      |> render_submit()

      assert [event] = all_enqueued(type: Audit.audit_type())
      assert event["payload"]["event_type"] == "url.added"
      assert event["queue"] == Audit.queue()
    end

    test "shows an error and enqueues nothing for a bad URL", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/")

      html =
        live
        |> form("form", %{"monitored_url" => %{"url" => "not a url"}})
        |> render_submit()

      assert html =~ "must be an http:// or https:// URL"
      refute_enqueued(type: CheckUrl.type())
    end

    test "shows an error for a duplicate", %{conn: conn} do
      url_fixture(%{url: "https://example.com/dup"})

      {:ok, live, _html} = live(conn, ~p"/")

      html =
        live
        |> form("form", %{"monitored_url" => %{"url" => "https://example.com/dup"}})
        |> render_submit()

      assert html =~ "already being monitored"
    end
  end

  describe "row actions" do
    test "removing a URL stops monitoring it", %{conn: conn} do
      url = url_fixture(%{url: "https://example.com/gone"})

      {:ok, live, _html} = live(conn, ~p"/")

      html = live |> element("#url-#{url.id} button[phx-click=delete]") |> render_click()

      # The row, not the URL string — the flash message names it too.
      refute html =~ ~s(id="url-#{url.id}")
      assert Monitors.get_url(url.id) == nil
    end

    test "check now enqueues a check", %{conn: conn} do
      url = url_fixture()

      {:ok, live, _html} = live(conn, ~p"/")

      live |> element("#url-#{url.id} button[phx-click=check]") |> render_click()

      assert_enqueued(type: CheckUrl.type(), payload: %{"id" => url.id})
    end
  end

  # The property that makes this page live rather than polled: work
  # done in a worker's process shows up here without the browser
  # asking.
  describe "live updates" do
    test "a check recorded elsewhere re-renders the page", %{conn: conn} do
      url = url_fixture(%{url: "https://example.com/live"})

      {:ok, live, html} = live(conn, ~p"/")
      assert html =~ "waiting"

      {:ok, _} = Monitors.record_check(url, CheckResult.up(http_status: 200))

      assert render(live) =~ "status-up"
      refute render(live) =~ "waiting"
    end

    test "a URL created elsewhere appears", %{conn: conn} do
      {:ok, live, html} = live(conn, ~p"/")
      assert html =~ "Nothing monitored yet."

      url_fixture(%{url: "https://example.com/appeared"})

      assert render(live) =~ "https://example.com/appeared"
    end
  end
end
