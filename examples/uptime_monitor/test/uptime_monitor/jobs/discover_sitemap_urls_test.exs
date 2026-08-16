defmodule UptimeMonitor.Jobs.DiscoverSitemapUrlsTest do
  use UptimeMonitor.DataCase
  use Zizq.Testing, client: UptimeMonitor.Zizq

  # Several cases deliberately drive the logged-and-carry-on paths.
  # The behaviour asserted is what happens to the children, not the
  # log line, so the output is kept out of the test run.
  @moduletag :capture_log

  alias UptimeMonitor.Jobs.CheckUrl
  alias UptimeMonitor.Jobs.DiscoverSitemapUrls

  @sitemap_url "https://example.com/sitemap.xml"

  defp stub(fun), do: Req.Test.stub(UptimeMonitor.HTTP, fun)

  defp serves(body, opts \\ []) do
    status = Keyword.get(opts, :status, 200)

    stub(fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/xml")
      |> Plug.Conn.send_resp(status, body)
    end)
  end

  defp sitemap_of(urls) do
    entries = Enum.map_join(urls, "", &"<url><loc>#{&1}</loc></url>")

    ~s(<?xml version="1.0"?><urlset>#{entries}</urlset>)
  end

  defp sitemap_fixture, do: url_fixture(%{url: @sitemap_url})

  describe "perform/1" do
    test "creates the URLs the sitemap lists" do
      sitemap = sitemap_fixture()
      serves(sitemap_of(["https://example.com/a", "https://example.com/b"]))

      assert :ok = perform_job(DiscoverSitemapUrls, %{"id" => sitemap.id})

      assert length(Monitors.sitemap_child_ids(@sitemap_url)) == 2
      assert Monitors.find_url("https://example.com/a", @sitemap_url).source == "sitemap"
    end

    test "enqueues an immediate check for each child" do
      sitemap = sitemap_fixture()
      serves(sitemap_of(["https://example.com/a", "https://example.com/b"]))

      assert :ok = perform_job(DiscoverSitemapUrls, %{"id" => sitemap.id})

      [a, b] = Monitors.sitemap_child_ids(@sitemap_url)
      assert_enqueued(type: CheckUrl.type(), payload: %{"id" => a})
      assert_enqueued(type: CheckUrl.type(), payload: %{"id" => b})
    end

    # One request for the batch, not one per URL — the reason
    # `enqueue_all/2` exists.
    test "enqueues the whole batch in a single request" do
      sitemap = sitemap_fixture()
      serves(sitemap_of(for n <- 1..25, do: "https://example.com/#{n}"))

      assert :ok = perform_job(DiscoverSitemapUrls, %{"id" => sitemap.id})

      assert length(all_enqueued(type: CheckUrl.type())) == 25
    end

    test "disables children the sitemap no longer lists" do
      sitemap = sitemap_fixture()
      serves(sitemap_of(["https://example.com/a", "https://example.com/gone"]))
      assert :ok = perform_job(DiscoverSitemapUrls, %{"id" => sitemap.id})

      gone = Monitors.find_url("https://example.com/gone", @sitemap_url)

      # The first pass legitimately enqueued a check for both children.
      # Forgetting it is what lets the refutation below speak about the
      # second pass alone.
      clear_enqueued()

      serves(sitemap_of(["https://example.com/a"]))
      assert :ok = perform_job(DiscoverSitemapUrls, %{"id" => sitemap.id})

      refute Monitors.get_url(gone.id).enabled
      refute_enqueued(type: CheckUrl.type(), payload: %{"id" => gone.id})
    end

    test "does not enqueue checks for disabled children" do
      sitemap = sitemap_fixture()

      # Seeded directly rather than by a first discovery run, which
      # would itself enqueue a check and make the refutation below
      # unable to tell the two runs apart.
      Monitors.reconcile_sitemap_children(@sitemap_url, ["https://example.com/gone"])
      gone = Monitors.find_url("https://example.com/gone", @sitemap_url)

      serves(sitemap_of([]))
      assert :ok = perform_job(DiscoverSitemapUrls, %{"id" => sitemap.id})

      refute Monitors.get_url(gone.id).enabled
      refute_enqueued(type: CheckUrl.type(), payload: %{"id" => gone.id})
    end

    test "emits an audit event describing the scan" do
      sitemap = sitemap_fixture()
      serves(sitemap_of(["https://example.com/a", "https://example.com/b"]))

      assert :ok = perform_job(DiscoverSitemapUrls, %{"id" => sitemap.id})

      assert [event] = all_enqueued(type: UptimeMonitor.Audit.audit_type())
      payload = event["payload"]

      assert payload["event_type"] == "sitemap.scanned"
      assert payload["resource"] == "monitored_url:#{sitemap.id}"
      assert payload["data"]["discovered_count"] == 2
      assert payload["data"]["created"] == 2
      assert event["queue"] == UptimeMonitor.Audit.queue()
    end

    # A sitemap index lists other sitemaps. Each becomes a monitored
    # URL, is probed, is flagged as a sitemap, and is discovered in
    # turn — nesting needs no special case.
    test "an index adds its child sitemaps as monitored URLs" do
      sitemap = sitemap_fixture()

      serves(~s(<?xml version="1.0"?><sitemapindex>
        <sitemap><loc>https://example.com/sitemap-1.xml</loc></sitemap>
      </sitemapindex>))

      assert :ok = perform_job(DiscoverSitemapUrls, %{"id" => sitemap.id})

      assert Monitors.find_url("https://example.com/sitemap-1.xml", @sitemap_url)
    end
  end

  describe "when the sitemap cannot be read" do
    setup do
      sitemap = sitemap_fixture()
      serves(sitemap_of(["https://example.com/a", "https://example.com/b"]))
      assert :ok = perform_job(DiscoverSitemapUrls, %{"id" => sitemap.id})

      %{sitemap: sitemap}
    end

    # The alternative is reading a truncated download as "this sitemap
    # is now empty" and disabling every URL in it.
    test "a malformed body leaves the children alone", %{sitemap: sitemap} do
      serves("<urlset><url><loc>https://exa")

      assert :ok = perform_job(DiscoverSitemapUrls, %{"id" => sitemap.id})

      assert length(Monitors.sitemap_child_ids(@sitemap_url)) == 2
    end

    test "a body that is not a sitemap leaves the children alone", %{sitemap: sitemap} do
      serves(~s(<?xml version="1.0"?><rss><channel/></rss>))

      assert :ok = perform_job(DiscoverSitemapUrls, %{"id" => sitemap.id})

      assert length(Monitors.sitemap_child_ids(@sitemap_url)) == 2
    end

    # Permanent as far as this job is concerned, so it succeeds rather
    # than burning three attempts to be told the same thing.
    test "a 404 succeeds and leaves the children alone", %{sitemap: sitemap} do
      serves("", status: 404)

      assert :ok = perform_job(DiscoverSitemapUrls, %{"id" => sitemap.id})

      assert length(Monitors.sitemap_child_ids(@sitemap_url)) == 2
    end

    # Transient, so worth another attempt.
    test "a 500 fails so the job retries", %{sitemap: sitemap} do
      serves("", status: 500)

      assert {:error, message} = perform_job(DiscoverSitemapUrls, %{"id" => sitemap.id})
      assert message =~ "HTTP 500"
    end

    test "an unreachable host fails so the job retries", %{sitemap: sitemap} do
      stub(fn conn -> Req.Test.transport_error(conn, :nxdomain) end)

      assert {:error, message} = perform_job(DiscoverSitemapUrls, %{"id" => sitemap.id})
      assert message =~ "sitemap fetch failed"
    end
  end

  describe "edge cases" do
    test "does nothing when the sitemap URL was deleted after enqueue" do
      sitemap = sitemap_fixture()
      {:ok, _} = Monitors.delete_url(sitemap)

      assert :ok = perform_job(DiscoverSitemapUrls, %{"id" => sitemap.id})
    end

    test "cancels a payload it cannot understand" do
      assert {:cancel, message} = perform_job(DiscoverSitemapUrls, %{"url" => @sitemap_url})

      assert message =~ "expected a payload"
    end
  end
end
