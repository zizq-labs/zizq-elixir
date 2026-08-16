defmodule UptimeMonitor.Jobs.CheckUrlTest do
  use UptimeMonitor.DataCase
  use Zizq.Testing, client: UptimeMonitor.Zizq

  alias UptimeMonitor.Jobs
  alias UptimeMonitor.Jobs.CheckUrl

  defp stub(fun), do: Req.Test.stub(UptimeMonitor.UrlProber, fun)

  defp responds(status, body \\ "") do
    stub(fn conn -> Plug.Conn.send_resp(conn, status, body) end)
  end

  describe "the job's declaration" do
    test "carries the type and queue producers agree on" do
      assert CheckUrl.type() == "uptime_monitor.check_url"
      assert CheckUrl.new(%{"id" => 1}).queue == Jobs.queue()
    end

    # Unlike the audit log, this app enqueues its own jobs, so the
    # defaults declared here are the ones actually used.
    test "declares a short retry ladder" do
      enqueue = CheckUrl.new(%{"id" => 1})

      assert enqueue.retry_limit == 3
      assert enqueue.backoff.base == :timer.seconds(5)
    end
  end

  describe "perform/1" do
    setup do
      %{url: url_fixture(%{url: "https://example.com"})}
    end

    test "probes the URL and records the result", %{url: url} do
      responds(200, "hello")

      assert :ok = perform_job(CheckUrl, %{"id" => url.id})

      assert [check] = Monitors.recent_checks(url)
      assert check.status == "up"
      assert check.http_status == 200

      assert Monitors.get_url(url.id).last_status == "up"
    end

    test "records a failure as a check rather than failing the job", %{url: url} do
      responds(503)

      assert :ok = perform_job(CheckUrl, %{"id" => url.id})

      assert [check] = Monitors.recent_checks(url)
      assert check.status == "down"
      assert check.error_message == "HTTP 503"
    end

    test "records an unreachable host as down", %{url: url} do
      stub(fn conn -> Req.Test.transport_error(conn, :nxdomain) end)

      assert :ok = perform_job(CheckUrl, %{"id" => url.id})

      assert [%{status: "down", error_message: "Host not found"}] = Monitors.recent_checks(url)
    end

    # A sweep enqueues from a snapshot, so by the time a job runs its
    # URL may be gone. That is ordinary, not an error.
    test "does nothing when the URL was deleted after enqueue", %{url: url} do
      {:ok, _} = Monitors.delete_url(url)

      assert :ok = perform_job(CheckUrl, %{"id" => url.id})
    end

    test "does nothing for a disabled URL" do
      disabled = url_fixture(%{url: "https://disabled.example.com", enabled: false})

      assert :ok = perform_job(CheckUrl, %{"id" => disabled.id})

      assert Monitors.recent_checks(disabled) == []
    end

    test "cancels a payload it cannot understand" do
      assert {:cancel, message} = perform_job(CheckUrl, %{"url" => "https://example.com"})

      assert message =~ "expected a payload"
    end

    test "cancels a payload whose id is not an integer" do
      assert {:cancel, _} = perform_job(CheckUrl, %{"id" => "42"})
    end
  end

  describe "the router" do
    test "dispatches check_url" do
      url = url_fixture()
      responds(200)

      assert :ok = perform_job(Jobs.router(), %{"id" => url.id}, type: CheckUrl.type())

      assert [%{status: "up"}] = Monitors.recent_checks(url)
    end
  end
end
