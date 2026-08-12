# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.TelemetryTest do
  @moduledoc """
  The events, their metadata, and the pairs that must always arrive
  together. Handlers are attached per test and detached after, so the
  suite stays async.
  """

  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias Zizq.FakeServer

  # `:telemetry` handlers are global, so a handler attached here also
  # fires for events emitted by other tests running concurrently.
  # Every event names the client or worker it came from, so `owner`
  # keeps a test to its own — without it, a sibling test's job arrives
  # here and is asserted against.
  defp attach(events, owner) do
    test_pid = self()
    handler_id = "test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, _ ->
          if metadata[:client] == owner or metadata[:worker] == owner do
            send(test_pid, {:telemetry, event, measurements, metadata})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  @enqueue_events [[:zizq, :enqueue, :start], [:zizq, :enqueue, :stop]]
  @job_events [[:zizq, :job, :start], [:zizq, :job, :stop], [:zizq, :job, :exception]]

  defp job_json(id) do
    JSON.encode!(%{
      "id" => id,
      "type" => "probe",
      "queue" => "default",
      "status" => "in_flight",
      "payload" => %{},
      "attempts" => 2
    }) <> "\n"
  end

  describe "[:zizq, :enqueue, _]" do
    # Attached here rather than in `setup`, since the client's name is
    # what scopes the handler and it does not exist until now.
    defp enqueue_server(status, body) do
      name =
        FakeServer.start_client!(
          fn conn -> FakeServer.respond(conn, status, "application/json", body) end,
          format: :json
        )

      attach(@enqueue_events, name)
      name
    end

    defp created_json do
      JSON.encode!(%{
        "id" => "01K9",
        "type" => "send_email",
        "queue" => "emails",
        "status" => "ready",
        "payload" => %{},
        "attempts" => 0
      })
    end

    test "a start and a stop, carrying the job's type and queue" do
      name = enqueue_server(201, created_json())

      {:ok, _job} = Zizq.enqueue([type: "send_email", queue: "emails"], name)

      assert_receive {:telemetry, [:zizq, :enqueue, :start], measurements, metadata}
      assert Map.has_key?(measurements, :system_time)
      assert metadata.client == name
      assert metadata.type == "send_email"
      assert metadata.queue == "emails"
      assert metadata.count == 1

      assert_receive {:telemetry, [:zizq, :enqueue, :stop], measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.outcome == :ok
      # The whole metadata survives to `:stop`, not just the outcome.
      assert metadata.type == "send_email"
      assert metadata.client == name
    end

    # A rejected enqueue returns an error rather than raising, so it
    # arrives as a `:stop` — a handler counting only `:exception` would
    # never see it.
    test "a rejected enqueue stops with an error outcome, not an exception" do
      name = enqueue_server(422, ~s({"error":"nope"}))

      {:error, _} = Zizq.enqueue([type: "send_email"], name)

      assert_receive {:telemetry, [:zizq, :enqueue, :stop], _measurements, metadata}
      assert metadata.outcome == :error
      assert %Zizq.Error{reason: :invalid_request} = metadata.error
    end

    test "a bulk enqueue is one span, counting the jobs" do
      name = enqueue_server(201, JSON.encode!(%{"jobs" => []}))

      {:ok, _} = Zizq.enqueue_all([[type: "a"], [type: "b"], [type: "c"]], name)

      assert_receive {:telemetry, [:zizq, :enqueue, :stop], _measurements, metadata}
      assert metadata.count == 3
      # Absent as a value rather than as a key, so a handler tagging by
      # type sees the same shape either way.
      assert metadata.type == nil
      assert metadata.queue == nil

      refute_receive {:telemetry, [:zizq, :enqueue, :stop], _, _}
    end

    test "an empty bulk enqueue contacts nothing and emits nothing" do
      name = enqueue_server(201, JSON.encode!(%{"jobs" => []}))

      {:ok, []} = Zizq.enqueue_all([], name)

      refute_receive {:telemetry, [:zizq, :enqueue, :start], _, _}
    end
  end

  describe "[:zizq, :job, _]" do
    setup do
      worker = :"tw_#{System.unique_integer([:positive])}"
      attach(@job_events, worker)

      test_pid = self()

      name =
        FakeServer.start_client!(
          fn conn ->
            case conn.request_path do
              "/jobs/take" ->
                send(test_pid, {:stream, self()})
                conn = Plug.Conn.send_chunked(conn, 200)

                receive do
                  {:emit, bytes} ->
                    {:ok, conn} = Plug.Conn.chunk(conn, bytes)
                    receive do: (:stop -> conn), after: (2_000 -> conn)
                after
                  2_000 -> conn
                end

              # A failure report expects the updated job back, not a
              # 204. Answering 204 makes the acker log an error from
              # its own process, after the test has finished and so
              # outside `capture_log`.
              path ->
                if String.ends_with?(path, "/failure") do
                  FakeServer.respond(
                    conn,
                    200,
                    "application/json",
                    ~s({"id":"a","type":"probe","queue":"default","status":"scheduled","attempts":1})
                  )
                else
                  FakeServer.respond(conn, 204, nil, "")
                end
            end
          end,
          format: :json
        )

      %{name: name, worker: worker}
    end

    defp start_worker!(ctx, handler) do
      start_supervised!(
        {Zizq.Worker, client: ctx.name, handler: handler, name: ctx.worker, drain_timeout: 500}
      )

      ctx.worker
    end

    test "a start and a stop around each job", ctx do
      worker = start_worker!(ctx, fn _job -> :ok end)
      assert_receive {:stream, server}
      send(server, {:emit, job_json("a")})

      assert_receive {:telemetry, [:zizq, :job, :start], measurements, metadata}
      assert Map.has_key?(measurements, :system_time)
      assert metadata.id == "a"
      assert metadata.type == "probe"
      assert metadata.queue == "default"
      assert metadata.attempts == 2
      assert metadata.worker == worker

      assert_receive {:telemetry, [:zizq, :job, :stop], measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.outcome == :ok
      assert metadata.id == "a"
    end

    # Two workers on one node are ordinary; without this the events
    # could not be told apart.
    test "the name distinguishes one worker's jobs from another's", ctx do
      worker = start_worker!(ctx, fn _job -> :ok end)
      assert_receive {:stream, server}
      send(server, {:emit, job_json("a")})

      assert_receive {:telemetry, [:zizq, :job, :stop], _measurements, metadata}
      assert metadata.worker == worker
      refute metadata.worker == Zizq.Worker
    end

    for {return, outcome} <- [
          {:ok, :ok},
          {{:ok, :value}, :ok},
          {{:error, "nope"}, :error},
          {{:cancel, :gone}, :cancel},
          {{:snooze, 60_000}, :snooze},
          {%{rows: 1}, :unknown}
        ] do
      test "an outcome of #{inspect(outcome)} is reported for #{inspect(return)}", ctx do
        start_worker!(ctx, fn _job -> unquote(Macro.escape(return)) end)
        assert_receive {:stream, server}
        send(server, {:emit, job_json("a")})

        assert_receive {:telemetry, [:zizq, :job, :stop], _measurements, metadata}
        assert metadata.outcome == unquote(outcome)
      end
    end

    # A raising handler produces no `:stop` at all, so counting only
    # `:stop` would undercount jobs.
    test "a raising handler produces an exception, not a stop", ctx do
      start_worker!(ctx, fn _job -> raise ArgumentError, "boom" end)
      assert_receive {:stream, server}
      send(server, {:emit, job_json("a")})

      assert_receive {:telemetry, [:zizq, :job, :exception], measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.kind == :error
      assert %ArgumentError{} = metadata.reason
      assert is_list(metadata.stacktrace)
      # Unlike `:stop`, the exception event keeps the start metadata.
      assert metadata.id == "a"

      refute_receive {:telemetry, [:zizq, :job, :stop], _, _}
    end
  end

  describe "[:zizq, :stream, _]" do
    test "connect fires when the server accepts the request" do
      test_pid = self()

      name =
        FakeServer.start_client!(
          fn conn ->
            send(test_pid, {:stream, self()})
            conn = Plug.Conn.send_chunked(conn, 200)
            receive do: (:stop -> conn), after: (2_000 -> conn)
          end,
          format: :json
        )

      attach([[:zizq, :stream, :connect]], name)
      start_supervised!({Zizq.Stream.Take, client: name, owner: self()})

      assert_receive {:telemetry, [:zizq, :stream, :connect], measurements, metadata}
      assert Map.has_key?(measurements, :system_time)
      assert metadata.client == name
      assert metadata.url =~ "http://"
    end

    test "disconnect fires when the connection ends, naming the reason" do
      name =
        FakeServer.start_client!(
          fn conn -> Plug.Conn.send_chunked(conn, 200) end,
          format: :json
        )

      attach([[:zizq, :stream, :disconnect]], name)
      start_supervised!({Zizq.Stream.Take, client: name, owner: self()})

      assert_receive {:telemetry, [:zizq, :stream, :disconnect], _measurements, metadata}
      assert metadata.client == name
      assert metadata.reason
    end
  end
end
