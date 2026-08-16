defmodule UptimeMonitor.Jobs.ScheduleChecksTest do
  use UptimeMonitor.DataCase
  use Zizq.Testing, client: UptimeMonitor.Zizq

  alias UptimeMonitor.Jobs.CheckUrl
  alias UptimeMonitor.Jobs.ScheduleChecks

  defp checked_at(url, at) do
    {:ok, _} = Monitors.record_check(url, CheckResult.up(checked_at: at))
  end

  defp ago(milliseconds) do
    DateTime.add(DateTime.utc_now(), -milliseconds, :millisecond)
  end

  describe "perform/1" do
    test "schedules a check for a URL never checked" do
      url = url_fixture()

      assert :ok = perform_job(ScheduleChecks, %{})

      assert_enqueued(type: CheckUrl.type(), payload: %{"id" => url.id})
    end

    test "schedules a check for a URL whose last check has gone stale" do
      url = url_fixture()
      checked_at(url, ago(ScheduleChecks.stale_after() + 1_000))

      assert :ok = perform_job(ScheduleChecks, %{})

      assert_enqueued(type: CheckUrl.type(), payload: %{"id" => url.id})
    end

    # The cron entry fires far more often than the check interval, so
    # most sweeps should find nothing to do.
    test "leaves a URL checked recently alone" do
      url = url_fixture()
      checked_at(url, ago(5_000))

      assert :ok = perform_job(ScheduleChecks, %{})

      refute_enqueued(type: CheckUrl.type(), payload: %{"id" => url.id})
    end

    test "leaves a disabled URL alone however stale" do
      url = url_fixture(%{enabled: false})

      assert :ok = perform_job(ScheduleChecks, %{})

      refute_enqueued(type: CheckUrl.type(), payload: %{"id" => url.id})
    end

    test "schedules one check per stale URL" do
      for n <- 1..3, do: url_fixture(%{url: "https://example.com/#{n}"})

      assert :ok = perform_job(ScheduleChecks, %{})

      assert length(all_enqueued(type: CheckUrl.type())) == 3
    end

    # One request for the sweep, not one per URL.
    test "sends the whole sweep in a single request" do
      for n <- 1..25, do: url_fixture(%{url: "https://example.com/#{n}"})

      assert :ok = perform_job(ScheduleChecks, %{})

      assert length(all_enqueued(type: CheckUrl.type())) == 25
    end

    test "does nothing when there is nothing due" do
      assert :ok = perform_job(ScheduleChecks, %{})

      assert all_enqueued() == []
    end

    test "ignores its payload, since the cron entry sends none" do
      url = url_fixture()

      assert :ok = perform_job(ScheduleChecks, %{"unexpected" => true})

      assert_enqueued(type: CheckUrl.type(), payload: %{"id" => url.id})
    end
  end

  describe "the schedule installed on the server" do
    test "owns one group, named for this app" do
      assert UptimeMonitor.Cron.group() == "uptime_monitor"
    end

    test "has one entry, enqueueing this job onto this app's queue" do
      assert [entry] = UptimeMonitor.Cron.entries()

      assert entry[:name] == "schedule_checks"
      assert entry[:job].type == ScheduleChecks.type()
      assert entry[:job].queue == UptimeMonitor.Jobs.queue()
    end

    # Six fields: the leading one is seconds, which the server treats
    # as optional.
    test "sweeps on a seconds-granularity expression" do
      [entry] = UptimeMonitor.Cron.entries()

      assert length(String.split(entry[:expression], " ")) == 6
    end

    # The cron fires as a heartbeat; this job decides what is due. So
    # the interval that matters is here, not in the expression.
    test "checks less often than it sweeps" do
      assert ScheduleChecks.stale_after() > :timer.seconds(5)
    end
  end
end
