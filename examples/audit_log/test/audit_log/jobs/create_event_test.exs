# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule AuditLog.Jobs.CreateEventTest do
  use AuditLog.DataCase
  use Zizq.Testing, client: AuditLog.Zizq

  alias AuditLog.Jobs
  alias AuditLog.Jobs.CreateEvent

  defp payload(overrides \\ %{}) do
    Map.merge(
      %{
        "occurred_at" => "2026-08-15T10:15:00Z",
        "source" => "uptime_monitor",
        "event_type" => "url.status.changed"
      },
      overrides
    )
  end

  describe "the cross-language contract" do
    # Producers in other applications and other languages enqueue
    # against this string. Renaming the module must not change it.
    test "the job type is audit.create" do
      assert CreateEvent.type() == "audit.create"
    end

    test "the queue is audit" do
      assert Jobs.queue() == "audit"
    end
  end

  describe "perform/1" do
    test "stores the event and acknowledges" do
      assert :ok = perform_job(CreateEvent, payload(%{"text" => "example.com went down"}))

      assert [event] = AuditLog.recent()
      assert event.source == "uptime_monitor"
      assert event.event_type == "url.status.changed"
      assert event.text == "example.com went down"
      assert event.occurred_at == ~U[2026-08-15 10:15:00.000000Z]
    end

    test "stores the structured data a producer sent" do
      assert :ok =
               perform_job(CreateEvent, payload(%{"data" => %{"from" => "up", "to" => "down"}}))

      assert [%{data: %{"from" => "up", "to" => "down"}}] = AuditLog.recent()
    end

    test "stores an event carrying only the required fields" do
      assert :ok = perform_job(CreateEvent, payload())

      assert AuditLog.count_events() == 1
    end

    # A payload the producer got wrong is wrong on every attempt, so
    # retrying it only delays the job dying with the same message.
    test "cancels rather than retries an invalid payload" do
      assert {:cancel, message} = perform_job(CreateEvent, %{"source" => "uptime_monitor"})

      assert message =~ "invalid audit event"
      assert message =~ "occurred_at can't be blank"
      assert AuditLog.count_events() == 0
    end

    test "cancels a payload whose timestamp is not ISO8601" do
      assert {:cancel, message} =
               perform_job(CreateEvent, payload(%{"occurred_at" => 1_786_788_900}))

      assert message =~ "occurred_at is invalid"
      assert AuditLog.count_events() == 0
    end

    test "cancels a payload that is not a JSON object" do
      assert {:cancel, message} = perform_job(CreateEvent, ["not", "an", "object"])

      assert message =~ "expected a JSON object payload"
      assert AuditLog.count_events() == 0
    end
  end

  describe "the router" do
    test "dispatches audit.create to the handler" do
      assert :ok = perform_job(Jobs.router(), payload(), type: "audit.create")

      assert AuditLog.count_events() == 1
    end

    # Retried rather than swallowed: during a rolling deploy a producer
    # on new code can reach a worker on old code, and the retry lands
    # somewhere that knows the type.
    test "raises on a type it does not know" do
      assert_raise Zizq.Router.UnknownJobType, fn ->
        perform_job(Jobs.router(), payload(), type: "audit.something_else")
      end

      assert AuditLog.count_events() == 0
    end
  end
end
