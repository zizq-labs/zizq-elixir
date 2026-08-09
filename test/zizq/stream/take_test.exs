# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Stream.TakeTest do
  @moduledoc """
  The stream against an in-process server, where the awkward cases —
  a mid-stream close, a rejected request, chunks split at unhelpful
  boundaries — can be produced on demand rather than waited for.
  """

  use ExUnit.Case, async: true

  # Reconnect warnings are expected here — several tests end the stream
  # deliberately. Captured per test, so they still surface on failure.
  @moduletag capture_log: true

  alias Zizq.FakeServer

  # Polls rather than sleeping a fixed amount: a slow machine only
  # makes this take longer, where a fixed wait would make it fail.
  defp eventually(condition, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(condition, deadline)
  end

  defp poll(condition, deadline) do
    cond do
      condition.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition was still false at the deadline")

      true ->
        Process.sleep(10)
        poll(condition, deadline)
    end
  end

  # `:sys.get_state/1` is a synchronous call, so it also acts as a
  # barrier: it is answered only after everything already queued.
  defp idle_timer(stream), do: :sys.get_state(stream).idle_timer

  # A chunked response the test drives, so traffic happens when the
  # test says rather than on a timer.
  defp serve(conn) do
    receive do
      {:emit, bytes} ->
        case Plug.Conn.chunk(conn, bytes) do
          {:ok, conn} -> serve(conn)
          {:error, :closed} -> conn
        end

      :stop ->
        conn
    after
      2_000 -> conn
    end
  end

  defp job_json(id, n) do
    JSON.encode!(%{
      "id" => id,
      "type" => "probe",
      "queue" => "default",
      "status" => "in_flight",
      "payload" => %{"n" => n},
      "attempts" => 0
    }) <> "\n"
  end

  # Streams whatever `chunks` contains, then ends the response.
  defp streaming_client(chunks, opts \\ []) do
    test_pid = self()

    FakeServer.start_client!(
      fn conn ->
        send(test_pid, {:stream_request, conn.request_path, conn.query_string, conn.req_headers})

        conn =
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/x-ndjson")
          |> Plug.Conn.send_chunked(200)

        Enum.reduce(chunks, conn, fn chunk, conn ->
          # The stream process may have gone away already (a test that
          # stops it, or a reconnect); a closed socket here is expected.
          case Plug.Conn.chunk(conn, chunk) do
            {:ok, conn} -> conn
            {:error, :closed} -> conn
          end
        end)
      end,
      Keyword.put_new(opts, :format, :json)
    )
  end

  describe "receiving jobs" do
    test "delivers each job to the owner as a Zizq.Job" do
      name = streaming_client([job_json("a", 1), job_json("b", 2)])

      start_supervised!({Zizq.Stream.Take, client: name, owner: self()})

      assert_receive {:zizq_stream, _, {:connected, _url}}
      assert_receive {:zizq_stream, _, {:job, %Zizq.Job{id: "a", payload: %{"n" => 1}}}}
      assert_receive {:zizq_stream, _, {:job, %Zizq.Job{id: "b", payload: %{"n" => 2}}}}
    end

    test "reassembles a job split across chunks" do
      whole = job_json("split", 1)
      {head, tail} = :erlang.split_binary(whole, div(byte_size(whole), 2))

      name = streaming_client([head, tail])
      start_supervised!({Zizq.Stream.Take, client: name, owner: self()})

      assert_receive {:zizq_stream, _, {:job, %Zizq.Job{id: "split"}}}
    end

    test "ignores heartbeats" do
      name = streaming_client(["\n", "\n", job_json("a", 1), "\n"])
      start_supervised!({Zizq.Stream.Take, client: name, owner: self()})

      assert_receive {:zizq_stream, _, {:job, %Zizq.Job{id: "a"}}}
      refute_receive {:zizq_stream, _, {:job, _}}, 100
    end
  end

  describe "the request" do
    test "asks for the streaming media type" do
      name = streaming_client([])
      start_supervised!({Zizq.Stream.Take, client: name, owner: self()})

      assert_receive({:stream_request, "/jobs/take", _query, headers})
      assert List.keyfind(headers, "accept", 0) == {"accept", "application/x-ndjson"}
    end

    test "sends prefetch and queues as query parameters" do
      name = streaming_client([])

      start_supervised!(
        {Zizq.Stream.Take,
         client: name, owner: self(), prefetch: 25, queues: ["emails", "reports"]}
      )

      assert_receive({:stream_request, "/jobs/take", query, _headers})
      params = URI.decode_query(query)

      assert params["prefetch"] == "25"
      # Comma-delimited, which is what the server's CommaSet expects.
      assert params["queue"] == "emails,reports"
    end

    test "omits parameters that were not set, so server defaults apply" do
      name = streaming_client([])
      start_supervised!({Zizq.Stream.Take, client: name, owner: self()})

      assert_receive({:stream_request, "/jobs/take", query, _headers})
      assert query in [nil, ""]
    end

    test "sends a worker id when given one" do
      name = streaming_client([])
      start_supervised!({Zizq.Stream.Take, client: name, owner: self(), worker_id: "worker-7"})

      assert_receive({:stream_request, _path, _query, headers})
      assert List.keyfind(headers, "worker-id", 0) == {"worker-id", "worker-7"}
    end
  end

  describe "disconnection" do
    test "reports a clean end of stream and reconnects" do
      name = streaming_client([job_json("a", 1)])

      start_supervised!({Zizq.Stream.Take, client: name, owner: self()})

      assert_receive {:zizq_stream, _, {:job, _}}
      assert_receive {:zizq_stream, _, {:disconnected, :closed}}

      # The stream is meant to live forever, so a closed body is a
      # reconnect rather than the end.
      assert_receive {:zizq_stream, _, {:connected, _}}
    end

    test "reports an incomplete final record rather than dropping it" do
      partial = job_json("a", 1) |> binary_part(0, 20)
      name = streaming_client([partial])

      start_supervised!({Zizq.Stream.Take, client: name, owner: self()})

      assert_receive {:zizq_stream, _, {:disconnected, %Zizq.Error{reason: :decode} = error}}
      assert Exception.message(error) =~ "ended mid-record"
    end
  end

  describe "idle timeout" do
    # The server heartbeats an otherwise idle stream, so silence means
    # the connection is gone. Without this a half-open socket would
    # leave the process waiting for jobs that can never arrive, with no
    # TCP error to notice.
    test "reconnects when nothing arrives, not even a heartbeat" do
      test_pid = self()

      name =
        FakeServer.start_client!(
          fn conn ->
            send(test_pid, :stream_opened)
            conn = Plug.Conn.send_chunked(conn, 200)
            # Hold the connection open, sending nothing at all. Only
            # has to outlast the 200ms idle timeout and the 250ms
            # reconnect backoff.
            Process.sleep(1_000)
            conn
          end,
          format: :json,
          stream_idle_timeout: 200
        )

      start_supervised!({Zizq.Stream.Take, client: name, owner: self()})

      assert_receive :stream_opened
      assert_receive {:zizq_stream, _, {:connected, _}}

      assert_receive {:zizq_stream, _, {:disconnected, %Zizq.Error{reason: :transport} = error}}
      assert Exception.message(error) =~ "not even a heartbeat"
      assert Zizq.Error.retryable?(error)

      # A dead connection is transient, so it reconnects rather than
      # giving up.
      assert_receive :stream_opened
    end

    # Asserted directly rather than inferred from the absence of a
    # disconnect. A "nothing happened within N milliseconds" test is
    # both the weakest claim available and the most sensitive to a
    # scheduler stall; reading the timer proves the reset happened and
    # cannot fail merely because the machine was busy.
    test "any traffic resets the idle clock, heartbeats included" do
      test_pid = self()

      name =
        FakeServer.start_client!(
          fn conn ->
            send(test_pid, {:server, self()})
            conn = Plug.Conn.send_chunked(conn, 200)
            serve(conn)
          end,
          format: :json
        )

      start_supervised!({Zizq.Stream.Take, client: name, owner: self()})

      assert_receive {:server, server}
      assert_receive {:zizq_stream, stream, {:connected, _}}

      before = idle_timer(stream)
      assert before

      # A bare newline is a heartbeat: no job, no owner message, so the
      # timer is the only observable effect it has.
      send(server, {:emit, "\n"})

      eventually(fn -> idle_timer(stream) != before end)

      send(server, :stop)
    end
  end

  describe "rejected requests" do
    # A 4xx will be answered identically next time, so looping on it
    # would be pointless. The process stops instead.
    test "stops rather than retrying, and reports the server's wording" do
      name =
        FakeServer.start_client!(
          fn conn ->
            FakeServer.respond(conn, 400, "application/json", ~s({"error":"invalid queue name"}))
          end,
          format: :json
        )

      Process.flag(:trap_exit, true)

      {:ok, pid} = Zizq.Stream.Take.start_link(client: name, owner: self())

      assert_receive {:zizq_stream, ^pid, {:disconnected, %Zizq.Error{} = error}}
      assert error.status == 400
      assert Exception.message(error) =~ "invalid queue name"

      assert_receive {:EXIT, ^pid, %Zizq.Error{status: 400}}
    end

    test "retries a 5xx, which may be transient" do
      name =
        FakeServer.start_client!(
          fn conn -> FakeServer.respond(conn, 503, "application/json", ~s({"error":"busy"})) end,
          format: :json
        )

      start_supervised!({Zizq.Stream.Take, client: name, owner: self()})

      assert_receive {:zizq_stream, _, {:disconnected, %Zizq.Error{status: 503}}}
      # Retried rather than stopped.
      assert_receive {:zizq_stream, _, {:disconnected, %Zizq.Error{status: 503}}}
    end
  end
end
