defmodule Zizq.Integration.SmokeTest do
  @moduledoc """
  Proves the harness itself works, independently of the client's API.

  These tests deliberately reach the server with `:httpc` from OTP
  rather than through `Zizq`, so that a harness failure (bad tarball
  extraction, server not started, URL misparsed) can never be mistaken
  for a client bug.
  """

  use ExUnit.Case, async: false

  setup_all do
    %{
      url: System.fetch_env!("ZIZQ_URL"),
      expected_version: System.fetch_env!("ZIZQ_EXPECTED_VERSION")
    }
  end

  test "the packaged client is the artifact under test", ctx do
    loaded = :zizq |> Application.spec(:vsn) |> to_string()

    # Guards against a stale or partial extraction silently leaving an
    # older client in place.
    assert loaded == ctx.expected_version
    assert Zizq.version() == loaded
  end

  test "the server under test is reachable", ctx do
    assert {:ok, {{_proto, 200, _reason}, _headers, _body}} =
             :httpc.request(:get, {~c"#{ctx.url}/health", []}, [], [])
  end

  test "the server under test is new enough for this client", ctx do
    {:ok, {{_, 200, _}, _headers, body}} =
      :httpc.request(:get, {~c"#{ctx.url}/version", []}, [], [])

    %{"version" => server_version} = body |> to_string() |> JSON.decode!()

    server = Version.parse!(server_version)
    client = Version.parse!(Zizq.version())

    # The compatibility rule, asserted rather than documented: a client
    # supports the server MAJOR.MINOR it targets *and anything newer
    # within that major*. Only two things are unsupported — a different
    # major, and a server older than the client. This is deliberately
    # not an equality check: `find-server-build.sh` hands us the newest
    # same-major server build, and the main zizq repo runs older
    # clients against newer servers as backward-compatibility coverage.
    assert server.major == client.major,
           "client #{Zizq.version()} targets major #{client.major}, " <>
             "but server is #{server_version}"

    assert server.minor >= client.minor,
           "client #{Zizq.version()} needs a server on #{client.major}.#{client.minor} " <>
             "or newer, but server is #{server_version}"
  end
end
