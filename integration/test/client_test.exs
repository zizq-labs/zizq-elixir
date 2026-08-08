defmodule Zizq.Integration.ClientTest do
  @moduledoc """
  End-to-end tests via the client itself, rather than `:httpc`.

  Coverage ensures that the endpoints receive and respond as expected, which
  the unit tests alone cannot guarantee.

  This also proves that HTTP/2 over cleartext works: the pool is configured
  `protocols: [:http2]` against an `http://` URL, so if the server did
  not speak h2c with prior knowledge, the connection would fail outright
  rather than quietly downgrading.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  setup do
    start_supervised!({Zizq, name: :itest, url: System.fetch_env!("ZIZQ_URL")})
    :ok
  end

  test "reports the server version over h2c" do
    assert {:ok, version} = Zizq.server_version(:itest)
    assert {:ok, %Version{}} = Version.parse(version)
  end

  test "works under either codec" do
    start_supervised!(
      {Zizq, name: :itest_json, url: System.fetch_env!("ZIZQ_URL"), format: :json}
    )

    assert {:ok, via_msgpack} = Zizq.server_version(:itest)
    assert {:ok, via_json} = Zizq.server_version(:itest_json)

    assert via_msgpack == via_json
  end

  test "several requests reuse the one multiplexed connection" do
    # Concurrent requests through a single HTTP/2 pool shard. If the
    # connection were not multiplexed these would serialise; either way
    # they must all succeed, which is what rules out a broken pool.
    results =
      1..25
      |> Task.async_stream(fn _ -> Zizq.server_version(:itest) end, max_concurrency: 25)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert results |> Enum.uniq() |> length() == 1
  end

  test "surfaces a transport error when the server is unreachable" do
    # Finch's HTTP/2 pool logs a warning for every failed connection
    # attempt and keeps retrying with backoff. That is deliberate
    # production behaviour — a client that cannot reach its queue
    # should say so — but here it would spray the suite's output, so
    # capture it rather than silencing Finch globally.
    #
    # The client is stopped inside the captured block, otherwise its
    # reconnect timer keeps firing warnings after capture ends.
    {result, log} =
      with_log(fn ->
        start_supervised!({Zizq, name: :itest_dead, url: "http://127.0.0.1:1"})
        result = Zizq.server_version(:itest_dead)
        stop_supervised!(:itest_dead)
        result
      end)

    assert {:error, error} = result
    assert Exception.message(error) =~ ~r/\S/

    # Assert the warning happens, rather than merely tolerating it: it
    # is the operator's only signal that enqueues are failing for an
    # infrastructure reason.
    assert log =~ "Failed to connect"
  end
end
