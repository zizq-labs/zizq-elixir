# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Codec.RoundTripTest do
  @moduledoc """
  One suite, run against every codec.

  The payload domain is the JSON value domain regardless of transport —
  the server types payloads as a JSON value and rejects MessagePack's
  `bin` type — so both codecs must agree on exactly what survives a
  round trip. Running the same assertions against both is what keeps
  them from drifting.
  """

  use ExUnit.Case, async: true

  @codecs [Zizq.Codec.JSON, Zizq.Codec.MessagePack]

  defp round_trip!(codec, term) do
    assert {:ok, encoded} = codec.encode(term)
    assert {:ok, decoded} = codec.decode(encoded)
    decoded
  end

  for codec <- @codecs do
    describe "#{inspect(codec)}" do
      test "round-trips JSON scalars unchanged" do
        codec = unquote(codec)

        for value <- [nil, true, false, 0, 1, -1, 42, 1_000_000_000_000, "", "hello", "héllo ✨"] do
          assert round_trip!(codec, value) == value, "failed for #{inspect(value)}"
        end
      end

      test "round-trips floats" do
        codec = unquote(codec)

        for value <- [0.0, 1.5, -1.5, 1.0e10] do
          assert round_trip!(codec, value) == value, "failed for #{inspect(value)}"
        end
      end

      test "round-trips containers, including empty ones" do
        codec = unquote(codec)

        for value <- [[], %{}, [1, 2, 3], ["a", "b"], [[1], [2]], %{"a" => 1, "b" => 2}] do
          assert round_trip!(codec, value) == value, "failed for #{inspect(value)}"
        end
      end

      test "round-trips a deeply nested payload" do
        codec = unquote(codec)

        payload = %{
          "user" => %{"id" => 42, "name" => "Ada", "tags" => ["admin", "beta"]},
          "meta" => %{"nested" => %{"deep" => [%{"x" => nil}, %{"y" => true}]}},
          "count" => 3
        }

        assert round_trip!(codec, payload) == payload
      end

      # Neither codec preserves atoms. Documented as a guarantee rather
      # than a wart: it is why `perform/2` can pattern match string keys
      # identically whichever codec is configured.
      test "atom keys and values come back as strings" do
        codec = unquote(codec)

        assert round_trip!(codec, %{status: :ready}) == %{"status" => "ready"}
        assert round_trip!(codec, %{a: 1, b: 2}) == %{"a" => 1, "b" => 2}
      end

      test "encode returns iodata, not necessarily a binary" do
        codec = unquote(codec)

        assert {:ok, encoded} = codec.encode(%{"a" => 1})
        # The HTTP layer writes iodata directly, so this must not be
        # forced into a binary just to be valid.
        assert is_list(encoded) or is_binary(encoded)
        assert IO.iodata_length(encoded) > 0
      end

      test "decode accepts iodata as well as a binary" do
        codec = unquote(codec)

        assert {:ok, encoded} = codec.encode(%{"a" => 1})
        binary = IO.iodata_to_binary(encoded)

        assert codec.decode(binary) == {:ok, %{"a" => 1}}
        assert codec.decode(encoded) == {:ok, %{"a" => 1}}
        # Split into an awkward iolist to prove no binary is assumed.
        <<head::binary-size(1), tail::binary>> = binary
        assert codec.decode([head, [tail]]) == {:ok, %{"a" => 1}}
      end

      test "decode returns an exception for malformed input" do
        codec = unquote(codec)

        assert {:error, error} = codec.decode(<<0xC1, 0xC1, 0xC1>>)
        # The message is user-facing when the client surfaces it, so
        # assert it is presentable rather than merely that it exists.
        assert Exception.message(error) =~ ~r/\S/
      end

      test "decode rejects trailing bytes after a complete value" do
        codec = unquote(codec)

        assert {:ok, encoded} = codec.encode(%{"a" => 1})
        trailing = IO.iodata_to_binary([encoded, "garbage"])

        assert {:error, _} = codec.decode(trailing)
      end
    end
  end

  describe "cross-codec compatibility" do
    # The server treats the two formats as interchangeable, so a
    # producer and a consumer may disagree about which to use.
    test "a payload encoded by one codec decodes identically under the other" do
      payload = %{
        "user_id" => 42,
        "template" => "welcome",
        "tags" => ["a", "b"],
        "nested" => %{"ok" => true, "missing" => nil}
      }

      assert {:ok, as_json} = Zizq.Codec.JSON.encode(payload)
      assert {:ok, as_msgpack} = Zizq.Codec.MessagePack.encode(payload)

      assert Zizq.Codec.JSON.decode(as_json) == Zizq.Codec.MessagePack.decode(as_msgpack)
    end
  end

  describe "invalid UTF-8" do
    # Elixir cannot distinguish a UTF-8 string from a byte array, so the
    # two codecs diverge on *where* raw bytes fail. Asserted so the
    # behaviour is pinned rather than incidental — see the note in
    # Zizq.Codec.MessagePack.
    test "JSON refuses to encode it locally" do
      assert {:error, error} = Zizq.Codec.JSON.encode(%{"data" => <<0xFF, 0xFE>>})

      # Worth pinning: the local failure names a byte but not the field
      # that carried it, so it is no more actionable than the server's
      # message on the MessagePack path.
      assert Exception.message(error) =~ "invalid_byte"
    end

    test "MessagePack encodes it as a str, and the server rejects it" do
      assert {:ok, encoded} = Zizq.Codec.MessagePack.encode(<<0xFF, 0xFE>>)
      # 0xA2 = fixstr of length 2. Not a `bin`, which the server would
      # also reject, but an invalid-UTF-8 `str`.
      assert IO.iodata_to_binary(encoded) == <<0xA2, 0xFF, 0xFE>>
    end
  end
end
