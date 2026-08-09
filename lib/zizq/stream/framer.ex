# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Stream.Framer do
  @moduledoc false
  # Turns the arbitrary byte chunks a socket delivers into whole
  # records.
  #
  # Deliberately pure and process-free: no sockets, no messages, no
  # state beyond the leftover bytes. The take stream is the hardest
  # part of the client to test end to end, and nearly all of the ways
  # it can go wrong are framing bugs: a record split across two TCP
  # segments, a heartbeat mistaken for a record, a length prefix
  # arriving before its body. Keeping that logic here means those cases
  # are ordinary unit tests rather than timing-dependent ones.
  #
  # Chunked transfer encoding is unwrapped by `Mint.HTTP1` before we see
  # anything, so chunk headers never appear here; only payload bytes.
  #
  # Both framings are matched with binary patterns, so the records
  # handed back are sub-binaries referencing the accumulated buffer
  # rather than copies.

  alias Zizq.Codec

  @type t :: %__MODULE__{codec: Codec.t(), framing: atom(), buffer: binary()}

  defstruct [:codec, :framing, buffer: <<>>]

  @doc "Start framing for a codec, using the framing that codec declares."
  @spec new(Codec.t()) :: t()
  def new(codec) do
    %__MODULE__{codec: codec, framing: codec.framing(), buffer: <<>>}
  end

  @doc """
  Add a chunk of bytes and take whatever complete records it produced.

  Returns the decoded records in arrival order along with the framer
  carrying any trailing partial record. Heartbeats are consumed and
  never surface. They exist to keep the connection alive, not to be
  handled.
  """
  @spec push(t(), binary()) :: {:ok, [term()], t()} | {:error, Exception.t()}
  def push(%__MODULE__{} = framer, chunk) when is_binary(chunk) do
    buffer = framer.buffer <> chunk

    case scan(framer.framing, framer.codec, buffer, []) do
      {:ok, records, rest} -> {:ok, records, %{framer | buffer: rest}}
      {:error, exception} -> {:error, exception}
    end
  end

  @doc """
  Assert the stream ended on a record boundary.

  Anything left buffered when the body ends cleanly means the server
  stopped mid-record, which is a broken framing contract rather than a
  normal end of stream. Better to be loud about a data integrity issue.
  """
  @spec finish(t()) :: :ok | {:error, Exception.t()}
  def finish(%__MODULE__{buffer: <<>>}), do: :ok

  def finish(%__MODULE__{buffer: buffer}) do
    {:error,
     %Zizq.Error{
       reason: :decode,
       message:
         "take stream ended mid-record with #{byte_size(buffer)} " <>
           "byte(s) of an incomplete frame buffered"
     }}
  end

  # --- Line-delimited (NDJSON) ---
  #
  # The server writes each job as JSON followed by "\n", and a
  # heartbeat as a bare "\n" — so an empty line is a heartbeat, not a
  # malformed record.

  defp scan(:line_delimited, codec, buffer, acc) do
    case :binary.split(buffer, "\n") do
      [line, rest] ->
        if blank?(line) do
          # skip heartbeat
          scan(:line_delimited, codec, rest, acc)
        else
          case codec.decode(line) do
            {:ok, record} -> scan(:line_delimited, codec, rest, [record | acc])
            {:error, exception} -> {:error, Zizq.Error.decode(exception)}
          end
        end

      [incomplete] ->
        {:ok, Enum.reverse(acc), incomplete}
    end
  end

  # --- Length-prefixed (MessagePack) ---
  #
  # Each record is a big-endian u32 byte count then that many bytes. A
  # zero count is a heartbeat and carries no payload.
  #
  # `unsigned-big` is Elixir's default for an integer segment, but it is
  # spelled out because this is a wire contract: the server writes
  # `(len as u32).to_be_bytes()`. Read little-endian, every length would
  # be wrong; read signed, a length above 2^31 would come out negative,
  # `binary-size/1` would never match it, and the stream would stall
  # forever waiting for bytes that had already arrived.

  defp scan(:length_prefixed, codec, <<0::unsigned-big-32, rest::binary>>, acc) do
    # skip empty heartbeat
    scan(:length_prefixed, codec, rest, acc)
  end

  defp scan(
         :length_prefixed,
         codec,
         <<len::unsigned-big-32, body::binary-size(len), rest::binary>>,
         acc
       ) do
    case codec.decode(body) do
      {:ok, record} -> scan(:length_prefixed, codec, rest, [record | acc])
      {:error, exception} -> {:error, Zizq.Error.decode(exception)}
    end
  end

  # Either fewer than four bytes of prefix, or a prefix whose body has
  # not fully arrived. Both are expected — wait for more bytes.
  defp scan(:length_prefixed, _codec, incomplete, acc) do
    {:ok, Enum.reverse(acc), incomplete}
  end

  # A heartbeat line is empty, but tolerate stray whitespace rather
  # than treating it as a malformed record.
  defp blank?(line), do: String.trim(line) == ""
end
