# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule AuditLog.ConfigTest do
  use ExUnit.Case, async: true

  # A regression guard, not a unit test.
  #
  # `config/config.exs` imports the environment's own config, and
  # anything set *after* that import silently wins over it. Getting
  # that order wrong once left `start_zizq?` true under test: the
  # suite started a real client and worker, talked to a real server,
  # and still passed — the damage was only visible on the server.
  #
  # Asserting on the running process rather than the config value,
  # because the process is what actually does the damage.
  test "the suite starts no Zizq client" do
    refute Application.get_env(:audit_log, :start_zizq?),
           "start_zizq? must be false under test — check config.exs does not " <>
             "set it after `import_config`"

    assert Process.whereis(AuditLog.Zizq) == nil,
           "a real Zizq client is running during the test suite"
  end
end
