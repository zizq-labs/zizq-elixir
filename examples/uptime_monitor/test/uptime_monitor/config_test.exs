defmodule UptimeMonitor.ConfigTest do
  use ExUnit.Case, async: true

  # A regression guard, not a unit test.
  #
  # `config/config.exs` imports the environment's own config at the
  # bottom, and anything set *after* that import silently wins over
  # it. Getting that order wrong once left `start_zizq?` true under
  # test: the suite started a real client and worker, drained a real
  # queue, and installed a cron schedule on a real server — and still
  # passed, because none of that is visible from inside the tests.
  #
  # Asserting on the running process rather than the config value,
  # because the process is what actually does the damage.
  test "the suite starts no Zizq client or worker" do
    refute Application.get_env(:uptime_monitor, :start_zizq?),
           "start_zizq? must be false under test — check config.exs does not " <>
             "set it after `import_config`"

    assert Process.whereis(UptimeMonitor.Zizq) == nil,
           "a real Zizq client is running during the test suite"
  end
end
