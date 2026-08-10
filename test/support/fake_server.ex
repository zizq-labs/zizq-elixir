# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.FakeServer do
  @moduledoc false
  # An in-process HTTP server for tests, so response handling can be
  # exercised without the integration harness and its real server
  # binary.
  #
  # Bandit rather than Bypass: Bypass is Cowboy-backed and speaks only
  # HTTP/1.1, but this client's pool is `protocols: [:http2]`, so
  # Bypass cannot answer it at all. Bandit serves HTTP/2 with prior
  # knowledge over a plain `:http` listener, which is exactly the
  # transport the client uses in production.
  #
  # The full round trip runs for real — Finch, Mint, h2c framing, HPACK
  # — and only the origin is faked. That is deliberate: mocking at the
  # Finch boundary instead would stub out the part most likely to
  # surprise us.

  @behaviour Plug

  @impl Plug
  def init(handler), do: handler

  @impl Plug
  def call(conn, handler), do: handler.(conn)

  @doc """
  Start a server for the current test and return its base URL.

  `handler` is a one-argument function receiving a `Plug.Conn` and
  returning a sent one. The server is supervised by ExUnit, so it stops
  when the test ends.

      url = FakeServer.start!(fn conn ->
        Plug.Conn.send_resp(conn, 404, ~s({"error":"nope"}))
      end)
  """
  @spec start!((Plug.Conn.t() -> Plug.Conn.t())) :: String.t()
  def start!(handler) when is_function(handler, 1) do
    pid =
      ExUnit.Callbacks.start_supervised!(
        {
          Bandit,
          # Long-lived streaming connections would otherwise hold
          # teardown open for ThousandIsland's default drain period,
          # which dwarfs the tests themselves. Nothing here needs a
          # graceful close.
          plug: {__MODULE__, handler},
          scheme: :http,
          port: 0,
          startup_log: false,
          thousand_island_options: [shutdown_timeout: 0]
        },
        id: {__MODULE__, System.unique_integer([:positive])}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}"
  end

  @doc """
  Start a server and a `Zizq` client pointed at it, returning the
  client's name.

  Covers the common case where a test only cares about what the client
  does with a given response.
  """
  @spec start_client!((Plug.Conn.t() -> Plug.Conn.t()), keyword()) :: atom()
  def start_client!(handler, opts \\ []) do
    url = start!(handler)
    name = :"zizq_fake_#{System.unique_integer([:positive])}"

    ExUnit.Callbacks.start_supervised!({Zizq, [name: name, url: url] ++ opts})

    name
  end

  @doc """
  Send a response with an explicit content type.

  `Plug.Conn.put_resp_content_type/2` appends `; charset=utf-8`, which
  is legitimate but obscures whether the client parses media type
  parameters; this sets the header verbatim.
  """
  @spec respond(Plug.Conn.t(), non_neg_integer(), String.t() | nil, iodata()) :: Plug.Conn.t()
  def respond(conn, status, content_type, body) do
    conn
    |> then(fn conn ->
      if content_type do
        Plug.Conn.put_resp_header(conn, "content-type", content_type)
      else
        conn
      end
    end)
    |> Plug.Conn.send_resp(status, body)
  end
end
