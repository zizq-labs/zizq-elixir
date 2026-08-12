defmodule Zizq.FakeServerTest do
  @moduledoc """
  The worker fake server's own guarantee: it answers every endpoint a
  worker uses, and refuses loudly rather than plausibly for anything
  else. A stub that quietly returns 204 to an unmodelled endpoint
  produces an error from the acker's process, after the test has
  finished — noise in an unrelated run rather than a failure here.
  """

  use ExUnit.Case, async: true
  @moduletag capture_log: true
  alias Zizq.FakeServer

  test "an endpoint the worker server does not model is reported, not faked" do
    name = FakeServer.start_worker_client!()

    assert {:error, %Zizq.Error{reason: :server_error}} =
             Zizq.enqueue([type: "a"], name)

    assert_receive {:unexpected_request, "/jobs"}
  end
end
