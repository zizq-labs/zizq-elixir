# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Codec.JSON do
  @moduledoc """
  JSON codec, built on Elixir's `JSON` module (OTP's `:json` underneath).

  Human-readable, and ideal for use with `curl` or HTTPie.
  `Zizq.Codec.MessagePack` is the default for its compactness; the two
  are interchangeable on every endpoint.
  """

  @behaviour Zizq.Codec

  @impl Zizq.Codec
  def content_type, do: "application/json"

  @impl Zizq.Codec
  def stream_content_type, do: "application/x-ndjson"

  @impl Zizq.Codec
  def framing, do: :line_delimited

  @impl Zizq.Codec
  def encode(term) do
    {:ok, JSON.encode_to_iodata!(term)}
  rescue
    e -> {:error, e}
  end

  # `decode!` rather than `decode`, because the bang variant raises a
  # `JSON.DecodeError` carrying a readable message and byte offset,
  # where the non-bang variant returns a bare reason term.
  @impl Zizq.Codec
  def decode(data) do
    {:ok, data |> IO.iodata_to_binary() |> JSON.decode!()}
  rescue
    e -> {:error, e}
  end
end
