# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Error do
  @moduledoc """
  The error returned by every `Zizq` function.

  Every failure arrives as `{:error, %Zizq.Error{}}` — a request the
  server rejected, a server that could not be reached, a body that
  would not encode — so there is a single shape to match on wherever
  the problem occurred. The `:reason` field says which kind it was.

      case Zizq.enqueue(MyApp.Zizq, job) do
        {:ok, job} ->
          job

        {:error, %Zizq.Error{reason: :forbidden}} ->
          needs_a_pro_license()

        {:error, %Zizq.Error{} = error} ->
          Logger.error(Exception.message(error))
      end

  Reasons are atoms, so a guard covers a whole class of failure when
  the specific one does not matter:

      {:error, %Zizq.Error{reason: reason}} when reason in [:not_found, :conflict] ->
        :already_handled

  ## Fields

    * `:reason` — the kind of failure; see `t:reason/0`
    * `:message` — human-readable, preferring the server's own wording
    * `:status` — the HTTP status, or `nil` when no response arrived
    * `:body` — the decoded response body, when there was one
    * `:cause` — the underlying exception behind a transport or codec
      failure, so the original detail is still available

  ## Deciding whether to retry

  Use `retryable?/1` rather than inspecting the status yourself. It
  keeps the policy in one place, and it is the same policy the worker
  applies to acknowledgements: transport failures and 5xx are
  transient, everything else is permanent.
  """

  @typedoc """
  Why the call failed.

    * `:not_found` — 404. A job or cron entry that does not exist.
    * `:conflict` — 409.
    * `:forbidden` — 403. The server refused a licensed feature; see
      the message for which one.
    * `:unsupported_format` — 406 or 415. Content negotiation failed,
      which indicates a client bug rather than bad input.
    * `:invalid_request` — 400 or 422. The server rejected the request.
    * `:client_error` — any other 4xx.
    * `:server_error` — any 5xx.
    * `:transport` — the request never completed: connection refused,
      timeout, DNS failure, pool unavailable.
    * `:encode` — the request body could not be serialised.
    * `:decode` — the response body could not be deserialised.
  """
  @type reason ::
          :not_found
          | :conflict
          | :forbidden
          | :unsupported_format
          | :invalid_request
          | :client_error
          | :server_error
          | :transport
          | :encode
          | :decode

  @type t :: %__MODULE__{
          reason: reason(),
          message: String.t(),
          status: non_neg_integer() | nil,
          body: term(),
          cause: Exception.t() | nil
        }

  defexception [:reason, :message, :status, :body, :cause]

  @doc """
  Build an error from a non-success HTTP response.

  Callers decide which statuses count as failures; the transport layer
  passes every status through untouched. That matters because status
  alone is not always enough: a 422 from the bulk acknowledge endpoint
  reports *partial success* (`{"not_found" => [...]}`, the rest having
  completed), where a 422 elsewhere is a genuine rejection.
  """
  @spec from_response(non_neg_integer(), term()) :: t()
  def from_response(status, body) do
    reason = reason_for_status(status)

    %__MODULE__{
      reason: reason,
      status: status,
      body: body,
      message: response_message(status, body)
    }
  end

  @doc "Wrap a transport-level failure."
  @spec transport(Exception.t()) :: t()
  def transport(cause) do
    %__MODULE__{
      reason: :transport,
      cause: cause,
      message: "could not reach the Zizq server: " <> Exception.message(cause)
    }
  end

  @doc "Wrap a request body that could not be serialised."
  @spec encode(Exception.t()) :: t()
  def encode(cause) do
    %__MODULE__{
      reason: :encode,
      cause: cause,
      message: "could not encode the request body: " <> Exception.message(cause)
    }
  end

  @doc "Wrap a response body that could not be deserialised."
  @spec decode(Exception.t()) :: t()
  def decode(cause) do
    %__MODULE__{
      reason: :decode,
      cause: cause,
      message: "could not decode the response body: " <> Exception.message(cause)
    }
  end

  @doc """
  Whether retrying the same request could plausibly succeed.

  True for `:transport` and `:server_error`; false for everything else.
  A 4xx will fail identically however many times it is sent, and a
  body that would not encode will not encode on a second attempt.

      iex> Zizq.Error.retryable?(%Zizq.Error{reason: :server_error})
      true

      iex> Zizq.Error.retryable?(%Zizq.Error{reason: :not_found})
      false

  """
  @spec retryable?(t()) :: boolean()
  def retryable?(%__MODULE__{reason: reason}), do: reason in [:transport, :server_error]

  # 406/415 are checked before the general 4xx bucket: they mean the
  # client sent an Accept or Content-Type the server cannot work with,
  # which is our bug, not the caller's input.
  defp reason_for_status(404), do: :not_found
  defp reason_for_status(409), do: :conflict
  defp reason_for_status(403), do: :forbidden
  defp reason_for_status(status) when status in [406, 415], do: :unsupported_format
  defp reason_for_status(status) when status in [400, 422], do: :invalid_request
  defp reason_for_status(status) when status in 400..499, do: :client_error
  defp reason_for_status(status) when status >= 500, do: :server_error

  # The server reports failures as `{"error": "..."}`; prefer that text
  # over a generic message, since it names the actual problem.
  defp response_message(status, %{"error" => detail}) when is_binary(detail) do
    "server returned #{status}: #{detail}"
  end

  defp response_message(status, _body), do: "server returned #{status}"
end
