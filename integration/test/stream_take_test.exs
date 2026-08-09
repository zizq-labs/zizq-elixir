# A codec that asks for a streaming media type the server does not
# serve, so the 406 path can be exercised for real. Everything else
# delegates to the JSON codec.
defmodule Zizq.Integration.BogusStreamCodec do
  @behaviour Zizq.Codec

  @impl Zizq.Codec
  defdelegate encode(term), to: Zizq.Codec.JSON

  @impl Zizq.Codec
  defdelegate decode(data), to: Zizq.Codec.JSON

  @impl Zizq.Codec
  def content_type, do: "application/json"

  @impl Zizq.Codec
  def stream_content_type, do: "application/x-nonsense"

  @impl Zizq.Codec
  def framing, do: :line_delimited
end

defmodule Zizq.Integration.StreamTakeTest do
  @moduledoc """
  Taking jobs from a real server.

  The framing, heartbeats and reconnection are covered by unit tests
  against an in-process server; what these add is the actual endpoint —
  that the request we build is one the server accepts, and that jobs
  enqueued through the client come back out the other side intact.
  """

  use ExUnit.Case, async: false

  @moduletag capture_log: true

  setup do
    url = System.fetch_env!("ZIZQ_URL")
    start_supervised!({Zizq, name: :stream_msgpack, url: url})
    start_supervised!({Zizq, name: :stream_json, url: url, format: :json})
    %{url: url}
  end

  defp take(client, count, opts) do
    opts = Keyword.merge([client: client, owner: self(), prefetch: count], opts)
    start_supervised!({Zizq.Stream.Take, opts}, id: {:stream, System.unique_integer([:positive])})

    assert_receive {:zizq_stream, _, {:connected, _}}, 5_000

    for _ <- 1..count do
      assert_receive {:zizq_stream, _, {:job, job}}, 5_000
      job
    end
  end

  test "streams enqueued jobs, payload intact" do
    queue = "stream_#{System.unique_integer([:positive])}"

    for n <- 1..5 do
      Zizq.enqueue!([type: "probe", queue: queue, payload: %{"n" => n}], :stream_msgpack)
    end

    jobs = take(:stream_msgpack, 5, queues: [queue])

    assert length(jobs) == 5
    assert Enum.all?(jobs, &match?(%Zizq.Job{status: :in_flight}, &1))
    assert jobs |> Enum.map(& &1.payload["n"]) |> Enum.sort() == [1, 2, 3, 4, 5]
    # Unlike bulk enqueue responses, the take stream does carry payloads.
    assert Enum.all?(jobs, &(&1.payload != nil))
  end

  test "decodes over the length-prefixed MessagePack framing" do
    queue = "mp_#{System.unique_integer([:positive])}"

    Zizq.enqueue!(
      [type: "probe", queue: queue, payload: %{"codec" => "msgpack"}],
      :stream_msgpack
    )

    assert [job] = take(:stream_msgpack, 1, queues: [queue])
    assert job.payload == %{"codec" => "msgpack"}
  end

  test "decodes over the NDJSON framing" do
    queue = "nd_#{System.unique_integer([:positive])}"
    Zizq.enqueue!([type: "probe", queue: queue, payload: %{"codec" => "json"}], :stream_json)

    assert [job] = take(:stream_json, 1, queues: [queue])
    assert job.payload == %{"codec" => "json"}
  end

  test "only takes from the queues it asked for" do
    mine = "mine_#{System.unique_integer([:positive])}"
    theirs = "theirs_#{System.unique_integer([:positive])}"

    Zizq.enqueue!([type: "probe", queue: theirs, payload: %{"q" => "theirs"}], :stream_msgpack)
    Zizq.enqueue!([type: "probe", queue: mine, payload: %{"q" => "mine"}], :stream_msgpack)

    assert [job] = take(:stream_msgpack, 1, queues: [mine])
    assert job.queue == mine

    # The other queue's job must not follow.
    refute_receive {:zizq_stream, _, {:job, _}}, 500
  end

  test "prefetch bounds how many arrive unacknowledged" do
    queue = "pf_#{System.unique_integer([:positive])}"

    for n <- 1..10 do
      Zizq.enqueue!([type: "probe", queue: queue, payload: %{"n" => n}], :stream_msgpack)
    end

    start_supervised!(
      {Zizq.Stream.Take, client: :stream_msgpack, owner: self(), prefetch: 3, queues: [queue]}
    )

    assert_receive {:zizq_stream, _, {:connected, _}}, 5_000

    for _ <- 1..3 do
      assert_receive {:zizq_stream, _, {:job, _}}, 5_000
    end

    # Nothing is acknowledged, so the server holds the rest back. This
    # is what bounds the process mailbox regardless of consumer speed.
    refute_receive {:zizq_stream, _, {:job, _}}, 1_000
  end

  # Note that `queue: "a,b"` is *not* a rejection here — on this
  # endpoint `queue` is a comma-delimited filter, so that asks for two
  # queues. An unservable Accept is the reachable 4xx.
  test "a rejected request stops the stream instead of looping", ctx do
    Process.flag(:trap_exit, true)

    start_supervised!(
      {Zizq, name: :stream_bogus, url: ctx.url, format: Zizq.Integration.BogusStreamCodec}
    )

    {:ok, pid} = Zizq.Stream.Take.start_link(client: :stream_bogus, owner: self())

    assert_receive {:zizq_stream, ^pid, {:disconnected, %Zizq.Error{} = error}}, 5_000
    assert error.status == 406
    assert error.reason == :unsupported_format
    refute Zizq.Error.retryable?(error)

    # Stopped rather than reconnecting, since the answer cannot change.
    assert_receive {:EXIT, ^pid, %Zizq.Error{status: 406}}, 5_000
  end
end
