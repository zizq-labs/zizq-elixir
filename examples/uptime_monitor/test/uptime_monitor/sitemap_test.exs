defmodule UptimeMonitor.SitemapTest do
  use ExUnit.Case, async: true

  alias UptimeMonitor.Sitemap

  describe "parse/1 on a urlset" do
    test "returns the listed URLs in document order" do
      body = """
      <?xml version="1.0" encoding="UTF-8"?>
      <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <url><loc>https://example.com/a</loc><priority>0.8</priority></url>
        <url><loc>https://example.com/b</loc></url>
      </urlset>
      """

      assert {:ok, ["https://example.com/a", "https://example.com/b"]} = Sitemap.parse(body)
    end

    test "trims whitespace around a URL" do
      body = """
      <urlset><url><loc>
          https://example.com/a
      </loc></url></urlset>
      """

      assert {:ok, ["https://example.com/a"]} = Sitemap.parse(body)
    end

    test "reads a URL wrapped in CDATA" do
      body = ~s(<urlset><url><loc><![CDATA[https://example.com/a]]></loc></url></urlset>)

      assert {:ok, ["https://example.com/a"]} = Sitemap.parse(body)
    end

    test "handles a namespace prefix on every element" do
      body = """
      <sm:urlset xmlns:sm="http://www.sitemaps.org/schemas/sitemap/0.9">
        <sm:url><sm:loc>https://example.com/a</sm:loc></sm:url>
      </sm:urlset>
      """

      assert {:ok, ["https://example.com/a"]} = Sitemap.parse(body)
    end

    test "decodes XML entities" do
      body = ~s(<urlset><url><loc>https://example.com/?a=1&amp;b=2</loc></url></urlset>)

      assert {:ok, ["https://example.com/?a=1&b=2"]} = Sitemap.parse(body)
    end

    test "skips an empty loc" do
      body =
        ~s(<urlset><url><loc></loc></url><url><loc>https://example.com/a</loc></url></urlset>)

      assert {:ok, ["https://example.com/a"]} = Sitemap.parse(body)
    end

    test "an empty sitemap lists nothing" do
      assert {:ok, []} = Sitemap.parse(~s(<urlset></urlset>))
    end
  end

  # An index lists other sitemaps. Treating its entries as URLs worth
  # monitoring means each is probed, flagged as a sitemap in turn, and
  # discovered — so nesting needs no special case here.
  describe "parse/1 on a sitemapindex" do
    test "returns the child sitemaps it lists" do
      body = """
      <?xml version="1.0" encoding="UTF-8"?>
      <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <sitemap><loc>https://example.com/sitemap-1.xml</loc></sitemap>
        <sitemap><loc>https://example.com/sitemap-2.xml</loc></sitemap>
      </sitemapindex>
      """

      assert {:ok, ["https://example.com/sitemap-1.xml", "https://example.com/sitemap-2.xml"]} =
               Sitemap.parse(body)
    end
  end

  describe "parse/1 on something else" do
    test "rejects well-formed XML that is not a sitemap" do
      body = ~s(<?xml version="1.0"?><rss version="2.0"><channel/></rss>)

      assert {:error, {:not_a_sitemap, "rss"}} = Sitemap.parse(body)
    end

    # A truncated download must not read as "this sitemap is now
    # empty", which would disable every URL in it.
    test "rejects a truncated document rather than returning what it read" do
      body = ~s(<urlset><url><loc>https://example.com/a</loc></url><url><loc>https://exa)

      assert {:error, {:malformed, _message}} = Sitemap.parse(body)
    end

    test "rejects a body that is not XML at all" do
      assert {:error, {:malformed, _}} = Sitemap.parse("not xml")
    end

    test "rejects an empty body" do
      assert {:error, {:malformed, _}} = Sitemap.parse("")
    end
  end
end
