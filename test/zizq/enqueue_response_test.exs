# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.EnqueueResponseTest do
  @moduledoc """
  What `enqueue/2` and `enqueue_all/2` make of the statuses the server
  actually answers with.

  A new job is 201; one that already existed is 200, carrying the
  existing job with `:duplicate` or `:folded` set. Both are success.
  """

  use ExUnit.Case, async: true

  alias Zizq.FakeServer

  defp job_json(overrides \\ %{}) do
    %{
      "id" => "01K9",
      "type" => "send_email",
      "queue" => "emails",
      "status" => "ready",
      "payload" => %{},
      "attempts" => 0
    }
    |> Map.merge(overrides)
    |> JSON.encode!()
  end

  defp server(status, body) do
    FakeServer.start_client!(
      fn conn -> FakeServer.respond(conn, status, "application/json", body) end,
      format: :json
    )
  end

  describe "enqueue/2" do
    test "201 is a newly created job" do
      name = server(201, job_json(%{"duplicate" => false}))

      assert {:ok, %Zizq.Job{id: "01K9", duplicate: false}} =
               Zizq.enqueue([type: "send_email"], name)
    end

    test "200 is an existing duplicate, not a failure" do
      name = server(200, job_json(%{"duplicate" => true}))

      assert {:ok, %Zizq.Job{id: "01K9", duplicate: true}} =
               Zizq.enqueue([type: "send_email", unique_key: "k"], name)
    end

    test "200 is also how a job folded into a batch comes back" do
      name = server(200, job_json(%{"folded" => true}))

      assert {:ok, %Zizq.Job{folded: true}} = Zizq.enqueue([type: "send_email"], name)
    end

    test "a genuine failure is still an error" do
      name = server(422, ~s({"error":"bad request"}))

      assert {:error, %Zizq.Error{reason: :invalid_request}} =
               Zizq.enqueue([type: "send_email"], name)
    end

    # Never a FunctionClauseError from inside the client: an
    # unrecognised status has to arrive as something matchable.
    test "an uninterpretable status is an error naming the status" do
      name = server(203, job_json())

      assert {:error, %Zizq.Error{reason: :unexpected_status, status: 203} = error} =
               Zizq.enqueue([type: "send_email"], name)

      assert Exception.message(error) =~ "203"
    end
  end

  describe "enqueue_all/2" do
    defp bulk(jobs), do: JSON.encode!(%{"jobs" => jobs})

    defp job_map(overrides) do
      Map.merge(
        %{
          "id" => "01K9",
          "type" => "send_email",
          "queue" => "emails",
          "status" => "ready",
          "payload" => %{},
          "attempts" => 0
        },
        overrides
      )
    end

    test "201 when jobs were created" do
      name = server(201, bulk([job_map(%{"id" => "a"}), job_map(%{"id" => "b"})]))

      assert {:ok, [%Zizq.Job{id: "a"}, %Zizq.Job{id: "b"}]} =
               Zizq.enqueue_all([[type: "send_email"], [type: "send_email"]], name)
    end

    test "200 when every job already existed" do
      name = server(200, bulk([job_map(%{"id" => "a", "duplicate" => true})]))

      assert {:ok, [%Zizq.Job{id: "a", duplicate: true}]} =
               Zizq.enqueue_all([[type: "send_email", unique_key: "k"]], name)
    end
  end
end
