# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.HTTPResponseTest do
  @moduledoc """
  What the client does with a server's response, over a real h2c
  connection to an in-process server. See `Zizq.FakeServer`.
  """

  use ExUnit.Case, async: true

  alias Zizq.Config
  alias Zizq.FakeServer
  alias Zizq.HTTP

  defp request(name, method \\ :get, path \\ "/version", body \\ nil) do
    HTTP.request(Config.fetch!(name), method, path, body)
  end

  describe "successful responses" do
    test "decodes a JSON body" do
      name =
        FakeServer.start_client!(
          fn conn ->
            FakeServer.respond(conn, 200, "application/json", ~s({"version":"9.9.9"}))
          end,
          format: :json
        )

      assert request(name) == {:ok, 200, %{"version" => "9.9.9"}}
    end

    test "decodes a MessagePack body" do
      packed = Msgpax.pack!(%{"version" => "9.9.9"}) |> IO.iodata_to_binary()

      name =
        FakeServer.start_client!(fn conn ->
          FakeServer.respond(conn, 200, "application/msgpack", packed)
        end)

      assert request(name) == {:ok, 200, %{"version" => "9.9.9"}}
    end

    test "tolerates media type parameters on the response" do
      name =
        FakeServer.start_client!(
          fn conn ->
            FakeServer.respond(conn, 200, "application/json; charset=utf-8", ~s({"ok":true}))
          end,
          format: :json
        )

      assert request(name) == {:ok, 200, %{"ok" => true}}
    end

    # The server may answer in a different format than requested, so
    # the response's own content-type wins over the configured codec.
    test "decodes by response content-type, not the configured codec" do
      name =
        FakeServer.start_client!(fn conn ->
          FakeServer.respond(conn, 200, "application/json", ~s({"from":"json"}))
        end)

      assert Config.fetch!(name).codec == Zizq.Codec.MessagePack
      assert request(name) == {:ok, 200, %{"from" => "json"}}
    end

    test "falls back to the configured codec when content-type is unrecognised" do
      packed = Msgpax.pack!(%{"a" => 1}) |> IO.iodata_to_binary()

      name =
        FakeServer.start_client!(fn conn ->
          FakeServer.respond(conn, 200, "application/octet-stream", packed)
        end)

      assert request(name) == {:ok, 200, %{"a" => 1}}
    end
  end

  describe "error responses" do
    # Status interpretation belongs to the caller, so 4xx/5xx come back
    # as `{:ok, status, body}` with the body decoded, not as errors.
    test "passes 4xx through with a decoded body" do
      name =
        FakeServer.start_client!(
          fn conn -> FakeServer.respond(conn, 404, "application/json", ~s({"error":"nope"})) end,
          format: :json
        )

      assert request(name) == {:ok, 404, %{"error" => "nope"}}
    end

    test "passes 5xx through with a decoded body" do
      name =
        FakeServer.start_client!(
          fn conn -> FakeServer.respond(conn, 500, "application/json", ~s({"error":"boom"})) end,
          format: :json
        )

      assert request(name) == {:ok, 500, %{"error" => "boom"}}
    end

    test "treats an empty body as nil rather than a decode failure" do
      name =
        FakeServer.start_client!(fn conn -> FakeServer.respond(conn, 204, nil, "") end)

      assert request(name) == {:ok, 204, nil}
    end

    test "returns an exception for a malformed body" do
      name =
        FakeServer.start_client!(
          fn conn -> FakeServer.respond(conn, 200, "application/json", "{not json") end,
          format: :json
        )

      assert {:error, %Zizq.Error{reason: :decode} = error} = request(name)
      # The underlying codec exception is kept, so the real cause is
      # not lost behind our wrapper.
      assert error.cause
      assert Exception.message(error) =~ "could not decode the response body"
    end

    test "returns an exception when the body cannot be encoded" do
      name =
        FakeServer.start_client!(fn conn -> FakeServer.respond(conn, 200, nil, "") end,
          format: :json
        )

      assert {:error, %Zizq.Error{reason: :encode} = error} =
               request(name, :post, "/jobs", %{"bad" => <<0xFF>>})

      assert Exception.message(error) =~ "could not encode the request body"
      assert Exception.message(error) =~ "invalid_byte"
    end
  end

  describe "outgoing request" do
    # The same contract asserted directly in Zizq.HTTPTest, checked here
    # over the wire — a bodyless request must not carry content-type.
    test "sends accept and no content-type when there is no body" do
      test_pid = self()

      name =
        FakeServer.start_client!(fn conn ->
          send(test_pid, {:headers, conn.req_headers, conn.method})

          FakeServer.respond(
            conn,
            200,
            "application/msgpack",
            Msgpax.pack!(%{}) |> IO.iodata_to_binary()
          )
        end)

      assert {:ok, 200, _} = request(name)
      assert_receive {:headers, headers, "GET"}

      assert List.keyfind(headers, "accept", 0) == {"accept", "application/msgpack"}
      refute List.keyfind(headers, "content-type", 0)
    end

    test "sends content-type and an encoded body on a write" do
      test_pid = self()

      name =
        FakeServer.start_client!(fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:request, conn.req_headers, conn.method, body})

          FakeServer.respond(
            conn,
            201,
            "application/msgpack",
            Msgpax.pack!(%{"id" => "x"}) |> IO.iodata_to_binary()
          )
        end)

      assert {:ok, 201, %{"id" => "x"}} = request(name, :post, "/jobs", %{"type" => "probe"})
      assert_receive {:request, headers, "POST", body}

      assert List.keyfind(headers, "content-type", 0) == {"content-type", "application/msgpack"}
      # The body really is MessagePack, not JSON that happens to parse.
      assert Msgpax.unpack!(body) == %{"type" => "probe"}
    end

    test "requests the configured path, including a proxy prefix" do
      test_pid = self()

      url =
        FakeServer.start!(fn conn ->
          send(test_pid, {:path, conn.request_path})
          FakeServer.respond(conn, 200, "application/json", ~s({}))
        end)

      name = :"prefix_#{System.unique_integer([:positive])}"
      start_supervised!({Zizq, name: name, url: url <> "/zizq", format: :json})

      assert {:ok, 200, %{}} = request(name)
      assert_receive {:path, "/zizq/version"}
    end
  end
end
