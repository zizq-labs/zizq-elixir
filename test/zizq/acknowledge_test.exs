# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.AcknowledgeTest do
  use ExUnit.Case, async: true

  alias Zizq.FakeServer

  defp echoing(status, body) do
    test_pid = self()

    FakeServer.start_client!(
      fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        decoded = if raw == "", do: nil, else: JSON.decode!(raw)
        send(test_pid, {:request, conn.method, conn.request_path, decoded})
        FakeServer.respond(conn, status, "application/json", body)
      end,
      format: :json
    )
  end

  describe "report_success/2" do
    test "posts to the job's success endpoint" do
      name = echoing(204, "")

      assert Zizq.report_success("job-1", name) == :ok
      assert_receive {:request, "POST", "/jobs/job-1/success", nil}
    end

    test "accepts a Zizq.Job as well as an id" do
      name = echoing(204, "")

      assert Zizq.report_success(%Zizq.Job{id: "job-2"}, name) == :ok
      assert_receive {:request, "POST", "/jobs/job-2/success", _}
    end

    # The work is done either way; the server simply no longer holds
    # the job in flight.
    test "reports an unknown job as :not_found" do
      name = echoing(404, ~s({"error":"job not found in in-flight set"}))

      assert {:error, %Zizq.Error{reason: :not_found} = error} =
               Zizq.report_success("gone", name)

      refute Zizq.Error.retryable?(error)
    end
  end

  describe "report_success_all/2" do
    test "posts every id in one request" do
      name = echoing(204, "")

      assert Zizq.report_success_all(["a", "b", "c"], name) == {:ok, []}
      assert_receive {:request, "POST", "/jobs/success", %{"ids" => ["a", "b", "c"]}}
    end

    test "accepts jobs as well as ids" do
      name = echoing(204, "")

      assert Zizq.report_success_all([%Zizq.Job{id: "a"}, "b"], name) == {:ok, []}
      assert_receive {:request, _, _, %{"ids" => ["a", "b"]}}
    end

    # 422 here is a partial success, not a failure: the recognised ids
    # were completed, and only the rest come back.
    test "treats 422 as a partial success and returns the missing ids" do
      name = echoing(422, ~s({"not_found":["b"]}))

      assert Zizq.report_success_all(["a", "b"], name) == {:ok, ["b"]}
    end

    test "an empty list makes no request" do
      name = echoing(204, "")

      assert Zizq.report_success_all([], name) == {:ok, []}
      refute_receive {:request, _, _, _}
    end

    test "a genuine failure is still an error" do
      name = echoing(500, ~s({"error":"boom"}))

      assert {:error, %Zizq.Error{reason: :server_error} = error} =
               Zizq.report_success_all(["a"], name)

      assert Zizq.Error.retryable?(error)
    end
  end

  describe "report_failure/3" do
    defp job_response do
      JSON.encode!(%{
        "id" => "job-1",
        "type" => "probe",
        "queue" => "default",
        "status" => "scheduled",
        "attempts" => 1
      })
    end

    test "returns the job as the server has now recorded it" do
      name = echoing(200, job_response())

      assert {:ok, %Zizq.Job{} = job} =
               Zizq.report_failure("job-1", name, message: "SMTP timeout")

      # The point of the 200 body: the new status and attempt count are
      # visible without a second request.
      assert job.status == :scheduled
      assert job.attempts == 1
    end

    test "sends only the message by default" do
      name = echoing(200, job_response())

      Zizq.report_failure("job-1", name, message: "boom")

      assert_receive {:request, "POST", "/jobs/job-1/failure", body}
      assert body == %{"message" => "boom"}
    end

    test "sends the optional diagnostics when given" do
      name = echoing(200, job_response())

      Zizq.report_failure("job-1", name,
        message: "boom",
        error_type: "Mint.TransportError",
        backtrace: "line one\nline two"
      )

      assert_receive {:request, _, _, body}
      assert body["error_type"] == "Mint.TransportError"
      assert body["backtrace"] == "line one\nline two"
    end

    # What a handler's {:cancel, reason} maps onto.
    test "kill is sent only when true" do
      name = echoing(200, job_response())

      Zizq.report_failure("job-1", name, message: "gone", kill: true)
      assert_receive {:request, _, _, %{"kill" => true}}

      Zizq.report_failure("job-1", name, message: "gone", kill: false)
      assert_receive {:request, _, _, body}
      refute Map.has_key?(body, "kill")
    end

    # What a handler's {:snooze, seconds} maps onto.
    test "retry_at accepts a DateTime or milliseconds" do
      name = echoing(200, job_response())
      at = ~U[2026-08-09 09:00:00.000Z]

      Zizq.report_failure("job-1", name, message: "later", retry_at: at)
      assert_receive {:request, _, _, body}
      assert body["retry_at"] == DateTime.to_unix(at, :millisecond)

      Zizq.report_failure("job-1", name, message: "later", retry_at: 1_786_172_985_237)
      assert_receive {:request, _, _, %{"retry_at" => 1_786_172_985_237}}
    end

    test "requires a message" do
      name = echoing(200, job_response())

      for opts <- [[], [message: nil], [message: ""]] do
        assert_raise ArgumentError, ~r/requires a non-empty :message/, fn ->
          Zizq.report_failure("job-1", name, opts)
        end
      end
    end

    test "rejects unknown options" do
      name = echoing(200, job_response())

      assert_raise ArgumentError, ~r/unknown failure/, fn ->
        Zizq.report_failure("job-1", name, message: "x", backtrce: "typo")
      end
    end
  end
end
