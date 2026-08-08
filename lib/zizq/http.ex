# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.HTTP do
  @moduledoc false
  # Request/response transport. The long-lived `/jobs/take` stream does
  # not go through here — it owns a Mint connection directly.

  alias Zizq.Config

  @type response :: {:ok, non_neg_integer(), term()} | {:error, Zizq.Error.t()}

  # Finch's HTTP/2 pool registers itself only once its connection is
  # established, and `Finch.request/3` does not wait for that: a
  # request arriving first gets `:pool_not_available` rather than
  # queueing. The window is normally a millisecond or two, but it is
  # real, and it lands squarely on the first request a freshly started
  # client makes — which is exactly when a user is deciding whether the
  # library works.
  #
  # This is deliberate Finch behaviour, not a defect awaiting a fix, so
  # do not delete this in the hope that a version bump has resolved it.
  # Finch 0.22.0 changed HTTP/2 pools to "register only ready
  # connections, returning `:pool_not_available` when no connected pool
  # is available". (0.23.0 fixed a *separate* `:pool_not_available`
  # race around dynamic pool supervisors; that one we get by requiring
  # `~> 0.23`.) Finch's own docs direct callers to retry.
  #
  # `:connection_not_ready` is the same situation one step later, while
  # the server's SETTINGS frame is outstanding.
  #
  # Both are startup conditions rather than failures, so they are
  # retried here instead of surfaced. The budget is deliberately short:
  # a genuinely unreachable server should still fail promptly.
  @readiness_reasons [:pool_not_available, :connection_not_ready]
  @readiness_backoff_ms [10, 25, 50, 100, 200, 400]

  @doc """
  Send a request and decode the response body.

  Returns `{:ok, status, decoded_body}` for any HTTP response,
  including 4xx and 5xx; interpreting status codes is the caller's
  job, because status alone is not always decisive (a 422 from bulk
  acknowledge reports partial success, not failure).

  `{:error, %Zizq.Error{}}` covers only the cases where there is no
  response to interpret: transport failures, and bodies that could not
  be encoded or decoded.
  """
  @spec request(Config.t(), atom(), String.t(), term() | nil) :: response()
  def request(%Config{} = config, method, path, body \\ nil) do
    with {:ok, headers, encoded} <- build_body(config, body) do
      method
      |> Finch.build(config.url <> path, headers, encoded)
      |> run(config, @readiness_backoff_ms)
      |> decode_response(config)
    end
  end

  defp run(request, config, backoff) do
    result = Finch.request(request, config.finch_name, receive_timeout: config.receive_timeout)

    case {result, backoff} do
      {{:error, %Finch.Error{reason: reason}}, [delay | rest]}
      when reason in @readiness_reasons ->
        Process.sleep(delay)
        run(request, config, rest)

      {result, _exhausted} ->
        result
    end
  end

  @doc false
  # Public only so the header contract can be asserted directly; this
  # module is internal.
  #
  # Note the two clauses: a request with no body sends `accept` alone
  # and no `content-type`. Content-Type describes content that is not
  # there, and while RFC 9110 does not forbid it, servers and proxies
  # in the wild do route and reject on it. Do not merge these into one
  # clause.
  def build_body(config, nil) do
    {:ok, [{"accept", config.codec.content_type()}], nil}
  end

  def build_body(config, body) do
    case config.codec.encode(body) do
      {:ok, iodata} ->
        headers = [
          {"accept", config.codec.content_type()},
          {"content-type", config.codec.content_type()}
        ]

        {:ok, headers, iodata}

      {:error, exception} ->
        {:error, Zizq.Error.encode(exception)}
    end
  end

  defp decode_response({:ok, %Finch.Response{status: status, body: ""}}, _config) do
    {:ok, status, nil}
  end

  defp decode_response({:ok, %Finch.Response{} = resp}, config) do
    codec = codec_for(resp.headers, config)

    case codec.decode(resp.body) do
      {:ok, decoded} -> {:ok, resp.status, decoded}
      {:error, exception} -> {:error, Zizq.Error.decode(exception)}
    end
  end

  defp decode_response({:error, exception}, _config),
    do: {:error, Zizq.Error.transport(exception)}

  # Trust the response's own content-type when we recognise it, so a
  # server that answers in a different format than requested still
  # decodes. Fall back to the configured codec otherwise.
  defp codec_for(headers, config) do
    with {_, value} <- List.keyfind(headers, "content-type", 0),
         {:ok, codec} <- Zizq.Codec.from_content_type(value) do
      codec
    else
      _ -> config.codec
    end
  end
end
