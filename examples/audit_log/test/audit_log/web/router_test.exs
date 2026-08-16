# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule AuditLog.Web.RouterTest do
  use AuditLog.DataCase

  import Plug.Test

  alias AuditLog.Web.Router

  @opts Router.init([])

  defp get(path) do
    :get |> conn(path) |> Router.call(@opts)
  end

  defp create!(attrs), do: AuditLog.create_event(event_attrs(attrs)) |> elem(1)

  describe "GET /" do
    test "renders an empty feed" do
      conn = get("/")

      assert conn.status == 200
      assert conn.resp_body =~ "No audit events yet."
    end

    test "renders the events" do
      create!(%{source: "billing_api", event_type: "invoice.refunded", text: "Refunded $24.00"})

      conn = get("/")

      assert conn.status == 200
      assert conn.resp_body =~ "billing_api"
      assert conn.resp_body =~ "invoice.refunded"
      assert conn.resp_body =~ "Refunded $24.00"
    end

    test "names the queue producers write to" do
      assert get("/").resp_body =~ "audit"
    end

    test "renders a producer's structured data" do
      create!(%{data: %{"amount_cents" => 2400}})

      assert get("/").resp_body =~ "amount_cents"
    end

    # Every value on this page came from a producer this app does not
    # control, and plain EEx interpolates whatever it is given.
    test "escapes text a producer sent" do
      create!(%{text: ~s|<script>alert("xss")</script>|})

      body = get("/").resp_body

      refute body =~ "<script>alert"
      assert body =~ "&lt;script&gt;"
    end

    test "escapes a source name too" do
      create!(%{source: ~s(evil"><script>)})

      body = get("/").resp_body

      refute body =~ ~s(evil"><script>)
      assert body =~ "&lt;script&gt;"
    end
  end

  describe "GET / with ?source=" do
    setup do
      create!(%{source: "billing_api", text: "a billing event"})
      create!(%{source: "uptime_monitor", text: "an uptime event"})
      :ok
    end

    test "narrows to one producer" do
      body = get("/?source=uptime_monitor").resp_body

      assert body =~ "an uptime event"
      refute body =~ "a billing event"
    end

    test "an unknown producer shows an empty feed" do
      assert get("/?source=nobody").resp_body =~ "No audit events yet."
    end

    test "a blank source is treated as no filter" do
      body = get("/?source=").resp_body

      assert body =~ "an uptime event"
      assert body =~ "a billing event"
    end
  end

  describe "GET / with ?cursor=" do
    setup do
      base = ~U[2026-08-15 10:00:00Z]

      for n <- 1..60 do
        create!(%{occurred_at: DateTime.add(base, n, :minute), text: "event #{n}"})
      end

      :ok
    end

    test "shows a page of 50 and offers an older page" do
      body = get("/").resp_body

      assert body =~ "event 60"
      assert body =~ "event 11"
      refute body =~ "event 10<"
      assert body =~ "Older"
      refute body =~ "Newest"
    end

    test "following the older link shows the rest" do
      cursor = get("/") |> older_cursor()

      body = get("/?cursor=#{URI.encode_www_form(cursor)}").resp_body

      assert body =~ "event 10"
      assert body =~ "event 1<"
      refute body =~ "event 60"
      assert body =~ "Newest"
    end

    # A cursor is user input, and someone will edit it in the URL bar.
    test "a malformed cursor shows the first page rather than failing" do
      for cursor <- ["nonsense", "123", "abc:def", ":", "99999999999999999999:1"] do
        conn = get("/?cursor=#{URI.encode_www_form(cursor)}")

        assert conn.status == 200, "expected #{inspect(cursor)} to be tolerated"
        assert conn.resp_body =~ "event 60"
      end
    end

    defp older_cursor(conn) do
      [_whole, cursor] = Regex.run(~r/cursor=([^"&]+)/, conn.resp_body)

      URI.decode_www_form(cursor)
    end
  end

  describe "other routes" do
    test "GET /up is a health check" do
      conn = get("/up")

      assert conn.status == 200
      assert conn.resp_body == "ok"
    end

    test "an unknown path is a 404" do
      assert get("/nope").status == 404
    end
  end
end
