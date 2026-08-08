# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.ErrorTest do
  use ExUnit.Case, async: true

  doctest Zizq.Error

  alias Zizq.Error

  describe "from_response/2 status mapping" do
    test "maps the statuses the server actually returns" do
      # Every status in `grep StatusCode:: handlers.rs` (Zizq server)
      # that is not a success, so a new one added server-side shows up
      # here as a gap.
      cases = [
        {400, :invalid_request},
        {403, :forbidden},
        {404, :not_found},
        {406, :unsupported_format},
        {409, :conflict},
        {415, :unsupported_format},
        {422, :invalid_request},
        {500, :server_error}
      ]

      for {status, expected} <- cases do
        assert Error.from_response(status, nil).reason == expected,
               "expected #{status} to map to #{expected}"
      end
    end

    test "falls back to broad buckets for unlisted statuses" do
      assert Error.from_response(418, nil).reason == :client_error
      assert Error.from_response(429, nil).reason == :client_error
      assert Error.from_response(502, nil).reason == :server_error
      assert Error.from_response(503, nil).reason == :server_error
    end

    test "keeps the status and body for inspection" do
      error = Error.from_response(404, %{"error" => "job not found"})

      assert error.status == 404
      assert error.body == %{"error" => "job not found"}
    end
  end

  describe "messages" do
    # The server reports failures as {"error": "..."}; that text names
    # the actual problem, so it must reach the user.
    test "prefer the server's own error text" do
      error = Error.from_response(403, %{"error" => "unique jobs requires a Pro license"})

      assert Exception.message(error) ==
               "server returned 403: unique jobs requires a Pro license"
    end

    test "fall back to the status alone when there is no error text" do
      assert Exception.message(Error.from_response(500, nil)) == "server returned 500"
      assert Exception.message(Error.from_response(500, %{"other" => 1})) == "server returned 500"
    end

    test "wrapped causes keep the underlying detail" do
      cause = %Mint.TransportError{reason: :econnrefused}

      assert Exception.message(Error.transport(cause)) =~ "could not reach the Zizq server"
      assert Exception.message(Error.transport(cause)) =~ "connection refused"
      assert Error.transport(cause).cause == cause
    end
  end

  describe "retryable?/1" do
    test "transport failures and 5xx are worth retrying" do
      assert Error.retryable?(Error.from_response(500, nil))
      assert Error.retryable?(Error.from_response(503, nil))
      assert Error.retryable?(Error.transport(%Mint.TransportError{reason: :closed}))
    end

    # This is the policy the worker applies to acknowledgements: a 4xx
    # will fail identically however many times it is sent, and a body
    # that would not encode will not encode on a second attempt.
    test "everything else is permanent" do
      for status <- [400, 403, 404, 406, 409, 415, 422, 429] do
        refute Error.retryable?(Error.from_response(status, nil)),
               "expected #{status} not to be retryable"
      end

      refute Error.retryable?(Error.encode(%RuntimeError{message: "x"}))
      refute Error.retryable?(Error.decode(%RuntimeError{message: "x"}))
    end
  end

  test "is a real exception, so it can be raised as well as returned" do
    error = Error.from_response(404, %{"error" => "nope"})

    assert_raise Zizq.Error, "server returned 404: nope", fn -> raise error end
  end
end
