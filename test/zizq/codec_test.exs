# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.CodecTest do
  use ExUnit.Case, async: true

  doctest Zizq.Codec

  alias Zizq.Codec

  describe "fetch!/1" do
    test "resolves the built-in shorthands" do
      assert Codec.fetch!(:json) == Codec.JSON
      assert Codec.fetch!(:msgpack) == Codec.MessagePack
    end

    test "accepts a module implementing the behaviour" do
      assert Codec.fetch!(Codec.JSON) == Codec.JSON
      assert Codec.fetch!(Codec.MessagePack) == Codec.MessagePack
    end

    test "rejects a module that isn't a codec" do
      assert_raise ArgumentError, ~r/Zizq.Codec behaviour/, fn ->
        Codec.fetch!(String)
      end
    end

    test "rejects a non-module" do
      assert_raise ArgumentError, ~r/expected :json, :msgpack/, fn ->
        Codec.fetch!("msgpack")
      end
    end
  end

  describe "from_content_type/1" do
    test "recognises request/response media types" do
      assert Codec.from_content_type("application/json") == {:ok, Codec.JSON}
      assert Codec.from_content_type("application/msgpack") == {:ok, Codec.MessagePack}
    end

    test "recognises streaming media types" do
      assert Codec.from_content_type("application/x-ndjson") == {:ok, Codec.JSON}

      assert Codec.from_content_type("application/vnd.zizq.msgpack-stream") ==
               {:ok, Codec.MessagePack}
    end

    test "ignores media type parameters" do
      for value <- [
            "application/json; charset=utf-8",
            "application/json;charset=utf-8",
            "application/json ; charset=utf-8"
          ] do
        assert Codec.from_content_type(value) == {:ok, Codec.JSON}, "failed for #{inspect(value)}"
      end
    end

    test "tolerates surrounding whitespace" do
      assert Codec.from_content_type("  application/msgpack  ") == {:ok, Codec.MessagePack}
    end

    # RFC 9110 makes media types case-insensitive, and a proxy is free
    # to rewrite them. The Rust client matches case-sensitively and
    # notes it as a known simplification; this is a deliberate,
    # strictly-more-permissive divergence.
    test "matches case-insensitively" do
      assert Codec.from_content_type("Application/JSON") == {:ok, Codec.JSON}
      assert Codec.from_content_type("APPLICATION/MSGPACK") == {:ok, Codec.MessagePack}
    end

    test "returns :error for anything unrecognised" do
      assert Codec.from_content_type("text/plain") == :error
      assert Codec.from_content_type("application/xml") == :error
      assert Codec.from_content_type("") == :error
    end
  end

  describe "media types" do
    test "match the values the server negotiates" do
      assert Codec.JSON.content_type() == "application/json"
      assert Codec.JSON.stream_content_type() == "application/x-ndjson"
      assert Codec.MessagePack.content_type() == "application/msgpack"
      assert Codec.MessagePack.stream_content_type() == "application/vnd.zizq.msgpack-stream"
    end

    test "every media type round-trips back to its own codec" do
      for codec <- [Codec.JSON, Codec.MessagePack],
          value <- [codec.content_type(), codec.stream_content_type()] do
        assert Codec.from_content_type(value) == {:ok, codec}
      end
    end
  end
end
