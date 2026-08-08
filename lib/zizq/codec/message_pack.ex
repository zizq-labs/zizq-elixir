# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Codec.MessagePack do
  @moduledoc """
  MessagePack codec, built on `Msgpax`. The default.

  ## Binaries are strings, not bytes

  Elixir does not distinguish a UTF-8 string from a byte array (both
  are `t:binary/0`) so `Msgpax` packs every binary as a MessagePack
  *str*, never a *bin*. That matches the server, which types payloads
  as JSON values and rejects `bin` outright, so `Msgpax.Bin` should be
  avoided.

  The consequence is that a binary which is not valid UTF-8 encodes
  without complaint locally but is refused by the server:

      HTTP 400  invalid MessagePack: string found to be invalid utf8

  Encode raw bytes as base64 in a string, exactly as JSON would
  require.
  """

  @behaviour Zizq.Codec

  @impl Zizq.Codec
  def content_type, do: "application/msgpack"

  @impl Zizq.Codec
  def stream_content_type, do: "application/vnd.zizq.msgpack-stream"

  @impl Zizq.Codec
  def encode(term) do
    {:ok, Msgpax.pack!(term)}
  rescue
    e -> {:error, e}
  end

  # `unpack!` rather than `unpack`, for the readable `Msgpax.UnpackError`.
  # Both reject trailing bytes, which is what we want for a complete
  # response body. The streaming decoder handles partial frames itself.
  @impl Zizq.Codec
  def decode(data) do
    {:ok, Msgpax.unpack!(data)}
  rescue
    e -> {:error, e}
  end
end
