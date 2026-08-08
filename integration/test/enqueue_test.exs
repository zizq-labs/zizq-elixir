defmodule Zizq.Integration.EnqueueTest do
  @moduledoc """
  Enqueue against a real server.

  Payloads are read back with `:httpc` and JSON rather than through the
  client, so a symmetrical bug in our own encoder and decoder cannot
  hide a wire-format mismatch: MessagePack goes out, JSON comes back,
  and the two have to agree.
  """

  use ExUnit.Case, async: false

  setup do
    url = System.fetch_env!("ZIZQ_URL")
    start_supervised!({Zizq, name: :enq_msgpack, url: url})
    start_supervised!({Zizq, name: :enq_json, url: url, format: :json})
    %{url: url}
  end

  # Independent read-back path: never the client under test.
  defp fetch_job!(url, id) do
    # `body_format: :binary` is essential, not cosmetic. Without it
    # :httpc hands back a charlist of raw bytes, and `to_string/1` then
    # re-encodes each byte as a codepoint — double-encoding any
    # non-ASCII text into mojibake and failing a comparison that the
    # client got right.
    {:ok, {{_, 200, _}, _headers, body}} =
      :httpc.request(
        :get,
        {~c"#{url}/jobs/#{id}", [{~c"accept", ~c"application/json"}]},
        [],
        body_format: :binary
      )

    JSON.decode!(body)
  end

  test "enqueues and returns the recorded job" do
    assert {:ok, job} = Zizq.enqueue(:enq_msgpack, type: "probe", payload: %{"n" => 1})

    assert %Zizq.Job{} = job
    assert is_binary(job.id)
    assert job.type == "probe"
    assert job.queue == "default"
    assert job.status == :ready
    assert job.attempts == 0
    assert %DateTime{} = job.ready_at
  end

  test "defaults the queue to \"default\" client-side" do
    assert {:ok, job} = Zizq.enqueue(:enq_msgpack, type: "probe")
    assert job.queue == "default"
  end

  describe "payload round trip" do
    @payload %{
      "int" => 42,
      "big_int" => 9_007_199_254_740_993,
      "negative" => -17,
      "float" => 1.5,
      "true" => true,
      "false" => false,
      "null" => nil,
      "string" => "héllo ✨",
      "empty_string" => "",
      "list" => [1, "two", 3.0, nil, true],
      "empty_list" => [],
      "map" => %{"nested" => %{"deep" => [1, 2]}},
      "empty_map" => %{}
    }

    test "survives MessagePack out, JSON back", ctx do
      assert {:ok, job} = Zizq.enqueue(:enq_msgpack, type: "probe", payload: @payload)

      assert fetch_job!(ctx.url, job.id)["payload"] == @payload
    end

    test "survives JSON out, JSON back", ctx do
      assert {:ok, job} = Zizq.enqueue(:enq_json, type: "probe", payload: @payload)

      assert fetch_job!(ctx.url, job.id)["payload"] == @payload
    end

    test "both codecs produce an identical stored payload", ctx do
      assert {:ok, via_msgpack} = Zizq.enqueue(:enq_msgpack, type: "probe", payload: @payload)
      assert {:ok, via_json} = Zizq.enqueue(:enq_json, type: "probe", payload: @payload)

      assert fetch_job!(ctx.url, via_msgpack.id)["payload"] ==
               fetch_job!(ctx.url, via_json.id)["payload"]
    end
  end

  describe "optional fields" do
    test "are stored as sent", ctx do
      assert {:ok, job} =
               Zizq.enqueue(:enq_msgpack,
                 type: "probe",
                 queue: "emails",
                 priority: 100,
                 retry_limit: 5,
                 backoff: [base: :timer.seconds(15), exponent: 4, jitter: :timer.seconds(30)],
                 retention: [completed: :timer.hours(24)]
               )

      assert job.queue == "emails"
      assert job.priority == 100

      stored = fetch_job!(ctx.url, job.id)
      assert stored["retry_limit"] == 5
      assert stored["backoff"] == %{"base_ms" => 15_000, "exponent" => 4.0, "jitter_ms" => 30_000}
      assert stored["retention"]["completed_ms"] == 86_400_000
    end

    test "a future ready_at schedules the job" do
      at = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert {:ok, job} = Zizq.enqueue(:enq_msgpack, type: "probe", ready_at: at)

      assert job.status == :scheduled
      # Round-tripped through Unix milliseconds, so compare at that
      # resolution rather than expecting the struct back unchanged.
      assert DateTime.to_unix(job.ready_at, :millisecond) == DateTime.to_unix(at, :millisecond)
    end

    test "omitted fields inherit the server's defaults" do
      assert {:ok, job} = Zizq.enqueue(:enq_msgpack, type: "probe")

      # Priority is assigned server-side, in the middle of the range.
      assert job.priority == 32_768
    end
  end

  describe "errors" do
    test "a rejected request maps to an invalid_request error" do
      # Commas are reserved in queue names; the server rejects them.
      assert {:error, %Zizq.Error{} = error} =
               Zizq.enqueue(:enq_msgpack, type: "probe", queue: "a,b")

      assert error.reason == :invalid_request
      assert error.status == 400
      # The server's own wording reaches the caller.
      assert Exception.message(error) =~ "server returned 400"
      refute Zizq.Error.retryable?(error)
    end

    test "enqueue!/2 raises the same error" do
      assert_raise Zizq.Error, ~r/server returned 400/, fn ->
        Zizq.enqueue!(:enq_msgpack, type: "probe", queue: "a,b")
      end
    end

    # Uniqueness is a licensed feature, so this asserts the union: with
    # a licence the enqueue succeeds, without one the server answers
    # 403 and the client must surface it as :forbidden.
    test "unique_key either works or reports :forbidden" do
      result = Zizq.enqueue(:enq_msgpack, type: "probe", unique_key: "k1", unique_while: :queued)

      case result do
        {:ok, %Zizq.Job{}} -> :ok
        {:error, %Zizq.Error{reason: :forbidden}} -> :ok
        other -> flunk("expected success or :forbidden, got: #{inspect(other)}")
      end
    end
  end
end
