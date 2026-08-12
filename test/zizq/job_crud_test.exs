# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.JobCrudTest do
  @moduledoc """
  Reading, changing and deleting one job.

  `update_job/3` gets most of the attention: it is JSON merge patch, so
  an absent option, `nil`, and a value are three different
  instructions, and getting that wrong silently changes the wrong
  thing.
  """

  use ExUnit.Case, async: true

  alias Zizq.FakeServer

  defp job_body(overrides \\ %{}) do
    %{
      "id" => "01K9",
      "type" => "send_email",
      "queue" => "emails",
      "status" => "ready",
      "payload" => %{"user_id" => 42},
      "attempts" => 0
    }
    |> Map.merge(overrides)
    |> JSON.encode!()
  end

  # Reports the request back, so a test can assert on what was sent as
  # well as on what came back.
  defp server(status, body) do
    test_pid = self()

    FakeServer.start_client!(
      fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        decoded = if raw == "", do: nil, else: JSON.decode!(raw)
        send(test_pid, {:request, conn.method, conn.request_path, decoded})

        FakeServer.respond(conn, status, if(body, do: "application/json"), body || "")
      end,
      format: :json
    )
  end

  describe "get_job/2" do
    test "returns the job, payload included" do
      name = server(200, job_body())

      assert {:ok, %Zizq.Job{id: "01K9", payload: %{"user_id" => 42}}} =
               Zizq.get_job("01K9", name)

      assert_receive {:request, "GET", "/jobs/01K9", nil}
    end

    test "takes a job as well as an id" do
      name = server(200, job_body())
      job = %Zizq.Job{id: "01K9"}

      assert {:ok, _} = Zizq.get_job(job, name)
      assert_receive {:request, "GET", "/jobs/01K9", _}
    end

    # Which is what a completed job becomes once its retention expires
    # — immediately, by default.
    test "a job the server no longer holds is :not_found" do
      name = server(404, ~s({"error":"no such job"}))

      assert {:error, %Zizq.Error{reason: :not_found}} = Zizq.get_job("gone", name)
    end

    test "the bang variant raises that error" do
      name = server(404, ~s({"error":"no such job"}))

      assert_raise Zizq.Error, fn -> Zizq.get_job!("gone", name) end
    end
  end

  describe "update_job/3" do
    test "sends only the fields given" do
      name = server(200, job_body())

      assert {:ok, %Zizq.Job{}} = Zizq.update_job("01K9", name, queue: "urgent", priority: 0)

      assert_receive {:request, "PATCH", "/jobs/01K9", body}
      assert body == %{"queue" => "urgent", "priority" => 0}
    end

    # The distinction the whole endpoint turns on: absent leaves a
    # field alone, `nil` clears it to the server's default.
    test "nil is sent, to clear a field to its default" do
      name = server(200, job_body())

      Zizq.update_job("01K9", name, retry_limit: nil)

      assert_receive {:request, "PATCH", "/jobs/01K9", body}
      assert body == %{"retry_limit" => nil}
      assert Map.has_key?(body, "retry_limit")
    end

    test "an omitted field is absent from the body entirely" do
      name = server(200, job_body())

      Zizq.update_job("01K9", name, priority: 5)

      assert_receive {:request, "PATCH", "/jobs/01K9", body}
      refute Map.has_key?(body, "retry_limit")
      refute Map.has_key?(body, "queue")
    end

    test "ready_at takes a DateTime or milliseconds" do
      name = server(200, job_body())
      at = ~U[2026-08-12 09:00:00Z]

      Zizq.update_job("01K9", name, ready_at: at)
      assert_receive {:request, "PATCH", _, %{"ready_at" => ms}}
      assert ms == DateTime.to_unix(at, :millisecond)

      Zizq.update_job("01K9", name, ready_at: 1_234)
      assert_receive {:request, "PATCH", _, %{"ready_at" => 1_234}}
    end

    test "backoff and retention are converted as an enqueue converts them" do
      name = server(200, job_body())

      Zizq.update_job("01K9", name,
        backoff: [base: :timer.seconds(15), exponent: 2.0, jitter: 0],
        retention: [completed: :timer.hours(1)]
      )

      assert_receive {:request, "PATCH", _, body}
      assert body["backoff"]["base_ms"] == 15_000
      assert body["retention"] == %{"completed_ms" => 3_600_000}
    end

    # The server merge-patches retention field by field, so naming one
    # must not clear the other.
    test "a retention patch names only the fields it changes" do
      name = server(200, job_body())

      Zizq.update_job("01K9", name, retention: [completed: :timer.hours(1)])

      assert_receive {:request, "PATCH", _, %{"retention" => retention}}
      refute Map.has_key?(retention, "dead_ms")
    end

    test "clearing backoff or retention outright sends null" do
      name = server(200, job_body())

      Zizq.update_job("01K9", name, backoff: nil, retention: nil)

      assert_receive {:request, "PATCH", _, body}
      assert body == %{"backoff" => nil, "retention" => nil}
    end

    test "returns the job as it now stands" do
      name = server(200, job_body(%{"queue" => "urgent", "priority" => 0}))

      assert {:ok, %Zizq.Job{queue: "urgent", priority: 0}} =
               Zizq.update_job("01K9", name, queue: "urgent", priority: 0)
    end

    # The server answers 422 with the same complaint; catching it here
    # turns a round trip into an error at the call site that got it
    # wrong.
    test "queue and priority cannot be cleared" do
      name = server(200, job_body())

      for field <- [:queue, :priority] do
        assert_raise ArgumentError, ~r/:#{field} cannot be nil/, fn ->
          Zizq.update_job("01K9", name, [{field, nil}])
        end
      end
    end

    test "an unknown field is rejected rather than dropped" do
      name = server(200, job_body())

      assert_raise ArgumentError, ~r/unknown update key/, fn ->
        Zizq.update_job("01K9", name, priorty: 1)
      end
    end

    # An empty patch would be a no-op round trip, which is never what
    # was meant.
    test "an empty update is rejected" do
      name = server(200, job_body())

      assert_raise ArgumentError, ~r/at least one field/, fn ->
        Zizq.update_job("01K9", name, [])
      end
    end

    test "a finished job is rejected by the server" do
      name = server(422, ~s({"error":"job is not editable"}))

      assert {:error, %Zizq.Error{reason: :invalid_request}} =
               Zizq.update_job("01K9", name, priority: 1)
    end

    test "the bang variant raises" do
      name = server(404, ~s({"error":"no such job"}))

      assert_raise Zizq.Error, fn -> Zizq.update_job!("gone", name, priority: 1) end
    end
  end

  describe "delete_job/2" do
    test "returns :ok on 204" do
      name = server(204, nil)

      assert Zizq.delete_job("01K9", name) == :ok
      assert_receive {:request, "DELETE", "/jobs/01K9", nil}
    end

    test "takes a job as well as an id" do
      name = server(204, nil)

      assert Zizq.delete_job(%Zizq.Job{id: "01K9"}, name) == :ok
      assert_receive {:request, "DELETE", "/jobs/01K9", _}
    end

    test "a job the server no longer holds is :not_found" do
      name = server(404, ~s({"error":"no such job"}))

      assert {:error, %Zizq.Error{reason: :not_found}} = Zizq.delete_job("gone", name)
    end

    test "the bang variant raises" do
      name = server(404, ~s({"error":"no such job"}))

      assert_raise Zizq.Error, fn -> Zizq.delete_job!("gone", name) end
    end
  end
end
