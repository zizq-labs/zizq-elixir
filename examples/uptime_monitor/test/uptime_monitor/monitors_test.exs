defmodule UptimeMonitor.MonitorsTest do
  use UptimeMonitor.DataCase

  describe "create_url/1" do
    test "starts monitoring a URL" do
      assert {:ok, url} = Monitors.create_url(%{url: "https://example.com"})

      assert url.url == "https://example.com"
      assert url.source == "manual"
      assert url.enabled
      assert url.consecutive_failures == 0
      assert url.last_checked_at == nil
    end

    test "trims surrounding whitespace" do
      assert {:ok, url} = Monitors.create_url(%{url: "  https://example.com  "})

      assert url.url == "https://example.com"
    end

    test "requires a URL" do
      assert {:error, changeset} = Monitors.create_url(%{url: ""})

      assert %{url: ["can't be blank"]} = errors_on(changeset)
    end

    # Without this a probe would be scheduled for something no request
    # can be made from, and fail once per sweep for ever.
    test "rejects anything that is not an http(s) URL with a host" do
      for candidate <- ["example.com", "file:///etc/passwd", "ftp://example.com", "https://", "?"] do
        assert {:error, changeset} = Monitors.create_url(%{url: candidate}),
               "expected #{inspect(candidate)} to be rejected"

        assert %{url: ["must be an http:// or https:// URL"]} = errors_on(changeset)
      end
    end

    test "accepts http and https" do
      assert {:ok, _} = Monitors.create_url(%{url: "http://example.com"})
      assert {:ok, _} = Monitors.create_url(%{url: "https://example.com/deep/path?q=1"})
    end

    test "the same URL cannot be monitored twice manually" do
      assert {:ok, _} = Monitors.create_url(%{url: "https://example.com"})
      assert {:error, changeset} = Monitors.create_url(%{url: "https://example.com"})

      assert %{url: ["is already being monitored"]} = errors_on(changeset)
    end

    # A URL can legitimately be both submitted by hand and listed by a
    # sitemap, and the two are tracked apart.
    test "the same URL can be monitored once per sitemap that lists it" do
      assert {:ok, _} = Monitors.create_url(%{url: "https://example.com/a"})

      assert {:ok, _} =
               Monitors.create_url(%{
                 url: "https://example.com/a",
                 source: "sitemap",
                 source_sitemap_url: "https://example.com/sitemap.xml"
               })

      assert {:ok, _} =
               Monitors.create_url(%{
                 url: "https://example.com/a",
                 source: "sitemap",
                 source_sitemap_url: "https://other.example.com/sitemap.xml"
               })
    end

    test "rejects an unknown source" do
      assert {:error, changeset} =
               Monitors.create_url(%{url: "https://example.com", source: "telepathy"})

      assert %{source: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "record_check/2" do
    setup do
      %{url: url_fixture(%{url: "https://example.com"})}
    end

    test "stores the check and rolls it up onto the URL", %{url: url} do
      result =
        CheckResult.up(
          http_status: 200,
          response_time_ms: 42,
          final_url: "https://example.com/",
          checked_at: ~U[2026-08-16 10:00:00Z]
        )

      assert {:ok, check} = Monitors.record_check(url, result)

      assert check.status == "up"
      assert check.http_status == 200
      assert check.response_time_ms == 42

      reloaded = Monitors.get_url(url.id)
      assert reloaded.last_status == "up"
      assert reloaded.last_checked_at == ~U[2026-08-16 10:00:00.000000Z]
    end

    test "counts consecutive failures", %{url: url} do
      {:ok, _} = Monitors.record_check(url, CheckResult.down(error_message: "HTTP 500"))
      assert Monitors.get_url(url.id).consecutive_failures == 1

      {:ok, _} = Monitors.record_check(Monitors.get_url(url.id), CheckResult.down())
      assert Monitors.get_url(url.id).consecutive_failures == 2
    end

    # "How long has this been down", not "how flaky has this ever been".
    test "a success clears the failure count", %{url: url} do
      {:ok, _} = Monitors.record_check(url, CheckResult.down())
      {:ok, _} = Monitors.record_check(Monitors.get_url(url.id), CheckResult.down())
      {:ok, _} = Monitors.record_check(Monitors.get_url(url.id), CheckResult.up())

      assert Monitors.get_url(url.id).consecutive_failures == 0
    end

    test "keeps every check, not just the last", %{url: url} do
      {:ok, _} = Monitors.record_check(url, CheckResult.down(error_message: "first"))
      {:ok, _} = Monitors.record_check(Monitors.get_url(url.id), CheckResult.up())

      assert [latest, previous] = Monitors.recent_checks(url)
      assert latest.status == "up"
      assert previous.error_message == "first"
    end

    test "records the error message from a failed probe", %{url: url} do
      {:ok, check} =
        Monitors.record_check(url, CheckResult.down(http_status: 503, error_message: "HTTP 503"))

      assert check.error_message == "HTTP 503"
      assert check.http_status == 503
    end
  end

  describe "stale_url_ids/1" do
    test "includes URLs never checked" do
      url = url_fixture()

      assert Monitors.stale_url_ids(60_000) == [url.id]
    end

    test "includes URLs checked longer ago than the threshold" do
      url = url_fixture()
      check_at(url, DateTime.add(DateTime.utc_now(), -120, :second))

      assert Monitors.stale_url_ids(60_000) == [url.id]
    end

    test "excludes URLs checked within the threshold" do
      url = url_fixture()
      check_at(url, DateTime.add(DateTime.utc_now(), -10, :second))

      assert Monitors.stale_url_ids(60_000) == []
    end

    test "excludes disabled URLs however stale" do
      _url = url_fixture(%{enabled: false})

      assert Monitors.stale_url_ids(60_000) == []
    end

    defp check_at(url, at) do
      {:ok, _} = Monitors.record_check(url, CheckResult.up(checked_at: at))
    end
  end

  describe "reconcile_sitemap_children/2" do
    @sitemap "https://example.com/sitemap.xml"

    test "creates URLs the sitemap lists for the first time" do
      assert {2, 0, 0} =
               Monitors.reconcile_sitemap_children(@sitemap, [
                 "https://example.com/a",
                 "https://example.com/b"
               ])

      assert length(Monitors.sitemap_child_ids(@sitemap)) == 2
    end

    test "leaves URLs it already knows about alone" do
      Monitors.reconcile_sitemap_children(@sitemap, ["https://example.com/a"])

      assert {0, 0, 0} = Monitors.reconcile_sitemap_children(@sitemap, ["https://example.com/a"])
      assert length(Monitors.sitemap_child_ids(@sitemap)) == 1
    end

    # Disabled rather than deleted: a page dropping out of a sitemap is
    # exactly when the checks recorded against it are worth keeping.
    test "disables URLs the sitemap no longer lists, keeping their history" do
      Monitors.reconcile_sitemap_children(@sitemap, [
        "https://example.com/a",
        "https://example.com/gone"
      ])

      gone = Monitors.find_url("https://example.com/gone", @sitemap)
      {:ok, _} = Monitors.record_check(gone, CheckResult.up())

      assert {0, 0, 1} = Monitors.reconcile_sitemap_children(@sitemap, ["https://example.com/a"])

      refute Monitors.get_url(gone.id).enabled
      assert Monitors.recent_checks(gone) != []
    end

    test "re-enables a URL that reappears" do
      Monitors.reconcile_sitemap_children(@sitemap, ["https://example.com/a"])
      Monitors.reconcile_sitemap_children(@sitemap, [])

      assert {0, 1, 0} = Monitors.reconcile_sitemap_children(@sitemap, ["https://example.com/a"])

      assert Monitors.find_url("https://example.com/a", @sitemap).enabled
    end

    test "ignores duplicates within one sitemap" do
      assert {1, 0, 0} =
               Monitors.reconcile_sitemap_children(@sitemap, [
                 "https://example.com/a",
                 "https://example.com/a"
               ])
    end

    test "skips entries that are not usable URLs" do
      assert {1, 0, 0} =
               Monitors.reconcile_sitemap_children(@sitemap, [
                 "https://example.com/a",
                 "not a url"
               ])

      assert length(Monitors.sitemap_child_ids(@sitemap)) == 1
    end

    test "does not touch another sitemap's children" do
      other = "https://other.example.com/sitemap.xml"
      Monitors.reconcile_sitemap_children(other, ["https://other.example.com/a"])

      Monitors.reconcile_sitemap_children(@sitemap, [])

      assert length(Monitors.sitemap_child_ids(other)) == 1
    end

    test "does not touch a manually added URL of the same address" do
      manual = url_fixture(%{url: "https://example.com/a"})
      Monitors.reconcile_sitemap_children(@sitemap, ["https://example.com/a"])

      Monitors.reconcile_sitemap_children(@sitemap, [])

      assert Monitors.get_url(manual.id).enabled
    end
  end

  describe "list_urls/0" do
    test "puts never-checked URLs first, so they read as waiting" do
      checked = url_fixture(%{url: "https://example.com/checked"})
      {:ok, _} = Monitors.record_check(checked, CheckResult.up())
      waiting = url_fixture(%{url: "https://example.com/waiting"})

      assert Enum.map(Monitors.list_urls(), & &1.id) == [waiting.id, checked.id]
    end
  end

  describe "delete_url/1" do
    test "removes the URL and its checks" do
      url = url_fixture()
      {:ok, check} = Monitors.record_check(url, CheckResult.up())

      assert {:ok, _} = Monitors.delete_url(url)

      assert Monitors.get_url(url.id) == nil
      assert Monitors.get_check(check.id) == nil
    end
  end
end
