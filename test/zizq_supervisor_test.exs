# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.SupervisorTest do
  @moduledoc """
  Startup and shutdown of a client. No server is involved — Finch pools
  connect lazily, so a client starts cleanly against an address that
  nothing is listening on.
  """

  use ExUnit.Case, async: false

  alias Zizq.Config

  @url "http://127.0.0.1:1"

  test "starts, registers its config, and starts a Finch instance" do
    start_supervised!({Zizq, name: :sup_test, url: @url})

    config = Config.fetch!(:sup_test)
    assert config.url == @url
    assert config.codec == Zizq.Codec.MessagePack

    assert Process.whereis(:sup_test) |> is_pid()
    assert Process.whereis(config.finch_name) |> is_pid()
  end

  test "removes its config on shutdown" do
    pid = start_supervised!({Zizq, name: :sup_stop_test, url: @url})
    assert Config.fetch!(:sup_stop_test)

    # The child id is the client's `:name`, not the module.
    :ok = stop_supervised(:sup_stop_test)
    refute Process.alive?(pid)

    # Otherwise a stopped client keeps answering, and the next failure
    # looks like a connection problem instead of "not started".
    assert_raise ArgumentError, ~r/no Zizq client named/, fn ->
      Config.fetch!(:sup_stop_test)
    end
  end

  # Each client's child id is its `:name`, so two can be listed in the
  # same tree directly — no `Supervisor.child_spec/2` wrapping needed
  # to dodge an id collision.
  test "several clients coexist under different names" do
    start_supervised!({Zizq, name: :multi_a, url: @url})
    start_supervised!({Zizq, name: :multi_b, url: @url, format: :json})

    assert Config.fetch!(:multi_a).codec == Zizq.Codec.MessagePack
    assert Config.fetch!(:multi_b).codec == Zizq.Codec.JSON
    refute Config.fetch!(:multi_a).finch_name == Config.fetch!(:multi_b).finch_name
  end

  test "invalid options fail at start, not at first request" do
    assert_raise NimbleOptions.ValidationError, fn ->
      Zizq.start_link(url: @url)
    end

    assert_raise ArgumentError, ~r/http or https/, fn ->
      Zizq.start_link(name: :bad_url, url: "nope")
    end
  end

  test "server_version/1 explains itself when the client isn't running" do
    assert_raise ArgumentError, ~r/no Zizq client named/, fn ->
      Zizq.server_version(:never_started)
    end
  end
end
