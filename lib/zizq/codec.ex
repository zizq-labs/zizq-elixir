# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Codec do
  @moduledoc """
  Serialization format used for request and response bodies.

  The Zizq server speaks both JSON and MessagePack on every endpoint,
  and the two are freely interchangeable: a job enqueued as MessagePack
  can be read back as JSON, so a producer and a consumer need not be
  configured with the same codec — or even be written in the same
  language. Choose `Zizq.Codec.MessagePack` (the default) for
  compactness, or `Zizq.Codec.JSON` when you want human-readable
  traffic.

  ## Payloads

  Whichever codec is in use, a job payload must be JSON-compatible.
  The server types payloads as a JSON value, so MessagePack's binary
  (`bin`) type is rejected. Encode raw bytes as base64 in a string,
  exactly as you would with JSON. Both codecs also hand payloads back
  with **string keys**, since neither preserves atoms, so `perform/2`
  pattern matches identically either way.

  ## Custom codecs

  The behaviour is public so a project stuck on an Elixir older than
  1.18 (before the built-in `JSON` module) can theoretically supply a
  `Jason`-backed codec without this library carrying the dependency.
  """

  @typedoc "A module implementing this behaviour."
  @type t :: module()

  @typedoc "Shorthand names for the built-in codecs."
  @type format :: :json | :msgpack

  @doc """
  Serialize a term into a request body.

  Returns iodata rather than a binary so the HTTP layer can write it
  without a final concatenation.
  """
  @callback encode(term()) :: {:ok, iodata()} | {:error, Exception.t()}

  @doc "Deserialize a response body. Accepts iodata."
  @callback decode(iodata()) :: {:ok, term()} | {:error, Exception.t()}

  @doc "Media type for request/response bodies."
  @callback content_type() :: String.t()

  @doc """
  How streaming endpoints delimit records.

    * `:line_delimited` — one record per line, terminated by `\\n`; an
      empty line is a heartbeat.
    * `:length_prefixed` — each record is a big-endian `u32` byte count
      followed by that many bytes; a zero length is a heartbeat.

  Declared here rather than inferred from the codec module so a custom
  codec can say which framing its format uses.
  """
  @callback framing() :: :line_delimited | :length_prefixed

  @doc """
  Media type for streaming endpoints.

  Streaming is framed differently from a request/response body
  (newline-delimited JSON, or length-prefixed MessagePack), so it
  negotiates a distinct media type.
  """
  @callback stream_content_type() :: String.t()

  @doc """
  Resolve a codec from a shorthand name, or validate a module.

  ## Examples

      iex> Zizq.Codec.fetch!(:msgpack)
      Zizq.Codec.MessagePack

      iex> Zizq.Codec.fetch!(Zizq.Codec.JSON)
      Zizq.Codec.JSON

  """
  @spec fetch!(format() | t()) :: t()
  def fetch!(:json), do: Zizq.Codec.JSON
  def fetch!(:msgpack), do: Zizq.Codec.MessagePack

  def fetch!(module) when is_atom(module) and not is_nil(module) do
    Code.ensure_loaded(module)

    if function_exported?(module, :encode, 1) and function_exported?(module, :decode, 1) do
      module
    else
      raise ArgumentError, """
      expected :json, :msgpack, or a module implementing the Zizq.Codec \
      behaviour, got: #{inspect(module)}\
      """
    end
  end

  def fetch!(other) do
    raise ArgumentError,
          "expected :json, :msgpack, or a Zizq.Codec module, got: #{inspect(other)}"
  end

  @doc """
  Resolve a codec from a `Content-Type` header value.

  Recognises both the request/response media types and the streaming
  ones, ignores any parameters (`; charset=utf-8`), and matches
  case-insensitively as RFC 9110 requires — a proxy is free to rewrite
  the casing. Returns `:error` for anything unrecognised so callers can
  fall back to the configured codec.

  ## Examples

      iex> Zizq.Codec.from_content_type("application/json; charset=utf-8")
      {:ok, Zizq.Codec.JSON}

      iex> Zizq.Codec.from_content_type("application/vnd.zizq.msgpack-stream")
      {:ok, Zizq.Codec.MessagePack}

      iex> Zizq.Codec.from_content_type("text/plain")
      :error

  """
  @spec from_content_type(String.t()) :: {:ok, t()} | :error
  def from_content_type(value) when is_binary(value) do
    value
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
    |> String.downcase()
    |> case do
      "application/json" -> {:ok, Zizq.Codec.JSON}
      "application/x-ndjson" -> {:ok, Zizq.Codec.JSON}
      "application/msgpack" -> {:ok, Zizq.Codec.MessagePack}
      "application/vnd.zizq.msgpack-stream" -> {:ok, Zizq.Codec.MessagePack}
      _ -> :error
    end
  end
end
