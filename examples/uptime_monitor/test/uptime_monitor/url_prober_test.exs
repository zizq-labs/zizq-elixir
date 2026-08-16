defmodule UptimeMonitor.UrlProberTest do
  use ExUnit.Case, async: true

  alias UptimeMonitor.UrlProber

  @sitemap """
  <?xml version="1.0" encoding="UTF-8"?>
  <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
    <url><loc>https://example.com/a</loc></url>
  </urlset>
  """

  defp stub(fun), do: Req.Test.stub(UptimeMonitor.HTTP, fun)

  defp respond(conn, status, body, headers \\ []) do
    Enum.reduce(headers, conn, fn {k, v}, acc -> Plug.Conn.put_resp_header(acc, k, v) end)
    |> Plug.Conn.send_resp(status, body)
  end

  describe "a successful response" do
    test "is up" do
      stub(fn conn -> respond(conn, 200, "hello") end)

      result = UrlProber.probe("https://example.com")

      assert result.status == "up"
      assert result.http_status == 200
      assert result.error_message == nil
      assert is_integer(result.response_time_ms)
      assert %DateTime{} = result.checked_at
    end

    test "every 2xx counts, not just 200" do
      for status <- [200, 201, 204, 299] do
        stub(fn conn -> respond(conn, status, "") end)

        assert UrlProber.probe("https://example.com").status == "up",
               "expected HTTP #{status} to be up"
      end
    end
  end

  describe "an unsuccessful response" do
    test "is down, with the status in the message" do
      stub(fn conn -> respond(conn, 500, "boom") end)

      result = UrlProber.probe("https://example.com")

      assert result.status == "down"
      assert result.http_status == 500
      assert result.error_message == "HTTP 500"
    end

    test "a 404 is down" do
      stub(fn conn -> respond(conn, 404, "") end)

      assert UrlProber.probe("https://example.com").status == "down"
    end
  end

  describe "transport failures" do
    test "a refused connection is down, not an exception" do
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      result = UrlProber.probe("https://example.com")

      assert result.status == "down"
      assert result.http_status == nil
      assert result.error_message == "Connection refused"
    end

    test "a timeout is down" do
      stub(fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert UrlProber.probe("https://example.com").error_message == "Timed out"
    end

    test "an unknown host is down" do
      stub(fn conn -> Req.Test.transport_error(conn, :nxdomain) end)

      assert UrlProber.probe("https://example.com").error_message == "Host not found"
    end
  end

  describe "redirects" do
    test "are followed, and the final URL is recorded" do
      stub(fn
        %{request_path: "/old"} = conn ->
          conn
          |> Plug.Conn.put_resp_header("location", "https://example.com/new")
          |> Plug.Conn.send_resp(302, "")

        conn ->
          respond(conn, 200, "arrived")
      end)

      result = UrlProber.probe("https://example.com/old")

      assert result.status == "up"
      assert result.final_url == "https://example.com/new"
    end

    test "a redirect loop is down rather than hanging" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://example.com/loop")
        |> Plug.Conn.send_resp(302, "")
      end)

      result = UrlProber.probe("https://example.com/loop")

      assert result.status == "down"
      assert result.error_message =~ "Too many redirects"
    end
  end

  describe "sitemap detection" do
    test "flags an XML sitemap" do
      stub(fn conn ->
        respond(conn, 200, @sitemap, [{"content-type", "application/xml"}])
      end)

      assert UrlProber.probe("https://example.com/sitemap.xml").sitemap?
    end

    test "flags a sitemap index" do
      body = ~s(<?xml version="1.0"?><sitemapindex><sitemap></sitemap></sitemapindex>)

      stub(fn conn -> respond(conn, 200, body, [{"content-type", "text/xml"}]) end)

      assert UrlProber.probe("https://example.com/sitemap.xml").sitemap?
    end

    test "sees through a namespace prefix" do
      body = ~s(<?xml version="1.0"?><sm:urlset xmlns:sm="http://x"><sm:url/></sm:urlset>)

      stub(fn conn -> respond(conn, 200, body, [{"content-type", "application/xml"}]) end)

      assert UrlProber.probe("https://example.com/sitemap.xml").sitemap?
    end

    test "does not flag other XML" do
      body = ~s(<?xml version="1.0"?><rss version="2.0"><channel/></rss>)

      stub(fn conn -> respond(conn, 200, body, [{"content-type", "application/xml"}]) end)

      refute UrlProber.probe("https://example.com/feed.xml").sitemap?
    end

    # A page that merely mentions a sitemap is not one.
    test "does not flag HTML that talks about sitemaps" do
      body = "<html><body>&lt;urlset&gt; is a sitemap element</body></html>"

      stub(fn conn -> respond(conn, 200, body, [{"content-type", "text/html"}]) end)

      refute UrlProber.probe("https://example.com").sitemap?
    end

    # The flag means "worth looking at properly", not "is a valid
    # sitemap". Parsing halts at the root element, so a truncated body
    # is still flagged — the discovery job re-fetches and parses in
    # full, and leaves the children alone if that fails. Validating
    # here instead would mean parsing every sitemap twice, on the path
    # walked once per URL per sweep.
    test "flags a truncated body, leaving the real parsing to discovery" do
      stub(fn conn ->
        respond(conn, 200, "<urlset><url>", [{"content-type", "application/xml"}])
      end)

      assert UrlProber.probe("https://example.com/broken.xml").sitemap?
    end

    test "does not flag a body with no elements at all" do
      stub(fn conn -> respond(conn, 200, "not xml", [{"content-type", "application/xml"}]) end)

      refute UrlProber.probe("https://example.com/broken.xml").sitemap?
    end

    test "a failed probe is never a sitemap" do
      stub(fn conn -> respond(conn, 500, @sitemap, [{"content-type", "application/xml"}]) end)

      refute UrlProber.probe("https://example.com/sitemap.xml").sitemap?
    end
  end
end
