defmodule UptimeMonitor.Jobs.NotifyWebhookTest do
  use UptimeMonitor.DataCase
  use Zizq.Testing, client: UptimeMonitor.Zizq

  @moduletag :capture_log

  alias UptimeMonitor.Jobs.NotifyWebhook

  @webhook "https://hooks.example.com/uptime"

  setup do
    Application.put_env(:uptime_monitor, :webhook_url, @webhook)
    on_exit(fn -> Application.put_env(:uptime_monitor, :webhook_url, nil) end)

    url = url_fixture(%{url: "https://example.com"})

    {:ok, check} =
      Monitors.record_check(
        url,
        CheckResult.down(
          http_status: 503,
          response_time_ms: 87,
          final_url: "https://example.com/",
          error_message: "HTTP 503",
          checked_at: ~U[2026-08-16 10:00:00Z]
        )
      )

    %{url: url, check: check}
  end

  defp stub(fun), do: Req.Test.stub(UptimeMonitor.HTTP, fun)

  defp responds(status, body \\ "") do
    stub(fn conn -> Plug.Conn.send_resp(conn, status, body) end)
  end

  describe "perform/1" do
    test "posts the transition to the webhook", %{check: check, url: url} do
      test_pid = self()

      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:posted, conn.method, Jason.decode!(body)})
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      assert :ok = perform_job(NotifyWebhook, %{"check_id" => check.id})

      assert_receive {:posted, "POST", body}
      assert body["check_id"] == check.id
      assert body["monitored_url_id"] == url.id
      assert body["url"] == "https://example.com"
      assert body["status"] == "down"
      assert body["http_status"] == 503
      assert body["response_time_ms"] == 87
      assert body["error_message"] == "HTTP 503"
      assert body["consecutive_failures"] == 1
      assert body["checked_at"] =~ "2026-08-16T10:00:00"
    end

    test "sends JSON", %{check: check} do
      test_pid = self()

      stub(fn conn ->
        send(test_pid, {:content_type, Plug.Conn.get_req_header(conn, "content-type")})
        Plug.Conn.send_resp(conn, 200, "")
      end)

      assert :ok = perform_job(NotifyWebhook, %{"check_id" => check.id})

      assert_receive {:content_type, [content_type]}
      assert content_type =~ "application/json"
    end

    test "any 2xx is a success", %{check: check} do
      for status <- [200, 201, 202, 204] do
        responds(status)

        assert :ok = perform_job(NotifyWebhook, %{"check_id" => check.id}),
               "expected HTTP #{status} to be accepted"
      end
    end
  end

  describe "when the receiver refuses" do
    # The receiver understood and said no. Another attempt gets the
    # same answer, so the ladder is not worth spending.
    test "a 4xx gives up without retrying", %{check: check} do
      responds(422, "no thanks")

      assert :ok = perform_job(NotifyWebhook, %{"check_id" => check.id})
    end

    test "a 5xx fails so the job retries", %{check: check} do
      responds(500)

      assert {:error, message} = perform_job(NotifyWebhook, %{"check_id" => check.id})
      assert message =~ "HTTP 500"
    end

    test "an unreachable receiver fails so the job retries", %{check: check} do
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, message} = perform_job(NotifyWebhook, %{"check_id" => check.id})
      assert message =~ "webhook request failed"
    end
  end

  describe "when there is nothing to send" do
    test "does nothing when no webhook is configured", %{check: check} do
      Application.put_env(:uptime_monitor, :webhook_url, nil)
      stub(fn _conn -> flunk("should not have made a request") end)

      assert :ok = perform_job(NotifyWebhook, %{"check_id" => check.id})
    end

    test "treats a blank webhook as unconfigured", %{check: check} do
      Application.put_env(:uptime_monitor, :webhook_url, "   ")
      stub(fn _conn -> flunk("should not have made a request") end)

      assert :ok = perform_job(NotifyWebhook, %{"check_id" => check.id})
    end

    test "does nothing when the check was deleted after enqueue", %{url: url, check: check} do
      {:ok, _} = Monitors.delete_url(url)
      stub(fn _conn -> flunk("should not have made a request") end)

      assert :ok = perform_job(NotifyWebhook, %{"check_id" => check.id})
    end

    test "cancels a payload it cannot understand" do
      assert {:cancel, message} = perform_job(NotifyWebhook, %{"id" => 1})

      assert message =~ "expected a payload"
    end
  end
end
