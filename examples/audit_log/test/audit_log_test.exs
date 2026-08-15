# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule AuditLogTest do
  use AuditLog.DataCase

  describe "create_event/1" do
    test "stores a valid event" do
      assert {:ok, event} = AuditLog.create_event(event_attrs())

      assert event.id
      assert event.created_at
      assert AuditLog.get_event(event.id).source == "billing_api"
    end

    test "returns the changeset when invalid" do
      assert {:error, changeset} = AuditLog.create_event(%{source: "billing_api"})

      refute changeset.valid?
    end

    test "round-trips structured data through the database" do
      attrs = event_attrs(%{data: %{"amount_cents" => 2400, "nested" => %{"ok" => true}}})

      {:ok, event} = AuditLog.create_event(attrs)

      assert AuditLog.get_event(event.id).data == %{
               "amount_cents" => 2400,
               "nested" => %{"ok" => true}
             }
    end
  end

  describe "record_payload/1" do
    test "stores an event from a producer's payload" do
      assert {:ok, event} =
               AuditLog.record_payload(%{
                 "occurred_at" => "2026-08-15T10:15:00Z",
                 "source" => "uptime_monitor",
                 "event_type" => "url.status.changed",
                 "text" => "https://example.com went down"
               })

      # Microsecond precision, since that is what the column stores.
      assert event.occurred_at == ~U[2026-08-15 10:15:00.000000Z]
      assert event.source == "uptime_monitor"
    end

    test "rejects a payload missing its required fields" do
      assert {:error, changeset} = AuditLog.record_payload(%{"source" => "uptime_monitor"})

      assert %{occurred_at: ["can't be blank"]} = errors_on(changeset)
    end

    # A producer that spells the timestamp some other way is told so,
    # rather than having it guessed at here and rejected elsewhere.
    test "rejects a payload whose timestamp is not ISO8601" do
      assert {:error, changeset} =
               AuditLog.record_payload(%{
                 "occurred_at" => 1_786_788_900,
                 "source" => "uptime_monitor",
                 "event_type" => "url.status.changed"
               })

      assert %{occurred_at: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "recent/1" do
    setup do
      base = ~U[2026-08-15 10:00:00Z]

      events =
        for minute <- 0..4 do
          {:ok, event} =
            AuditLog.create_event(
              event_attrs(%{
                occurred_at: DateTime.add(base, minute, :minute),
                source: if(rem(minute, 2) == 0, do: "billing_api", else: "uptime_monitor"),
                text: "event #{minute}"
              })
            )

          event
        end

      %{events: events}
    end

    test "returns events most recent first", %{events: events} do
      assert Enum.map(AuditLog.recent(), & &1.text) ==
               events |> Enum.reverse() |> Enum.map(& &1.text)
    end

    test "limits how many come back" do
      assert length(AuditLog.recent(limit: 2)) == 2
    end

    test "narrows to one producer" do
      recent = AuditLog.recent(source: "uptime_monitor")

      assert length(recent) == 2
      assert Enum.all?(recent, &(&1.source == "uptime_monitor"))
    end

    test "an unknown producer matches nothing" do
      assert AuditLog.recent(source: "nobody") == []
    end

    test "pages with a cursor, without skipping or repeating" do
      [first_page_last | _] = AuditLog.recent(limit: 2) |> Enum.reverse()

      second_page = AuditLog.recent(limit: 2, before: AuditLog.cursor(first_page_last))

      assert length(second_page) == 2
      assert Enum.map(second_page, & &1.text) == ["event 2", "event 1"]
    end

    test "walking every page yields each event exactly once", %{events: events} do
      walked = walk_pages(nil, [])

      assert length(walked) == length(events)
      assert Enum.uniq(walked) == walked
    end

    # Events sharing a timestamp are the case an offset-free cursor
    # has to get right, since occurred_at alone cannot order them.
    test "pages correctly when timestamps collide" do
      at = ~U[2026-08-15 11:00:00Z]

      for n <- 1..4 do
        AuditLog.create_event(event_attrs(%{occurred_at: at, text: "same time #{n}"}))
      end

      walked = walk_pages(nil, [])

      assert Enum.uniq(walked) == walked
      assert length(walked) == AuditLog.count_events()
    end

    defp walk_pages(cursor, acc) do
      opts = if cursor, do: [limit: 2, before: cursor], else: [limit: 2]

      case AuditLog.recent(opts) do
        [] -> acc
        page -> walk_pages(AuditLog.cursor(List.last(page)), acc ++ Enum.map(page, & &1.id))
      end
    end
  end

  describe "count_events/1" do
    test "counts everything, or one producer's share" do
      AuditLog.create_event(event_attrs(%{source: "billing_api"}))
      AuditLog.create_event(event_attrs(%{source: "billing_api"}))
      AuditLog.create_event(event_attrs(%{source: "uptime_monitor"}))

      assert AuditLog.count_events() == 3
      assert AuditLog.count_events(source: "billing_api") == 2
    end
  end

  describe "sources/1" do
    test "lists the distinct producers, alphabetically" do
      AuditLog.create_event(event_attrs(%{source: "uptime_monitor"}))
      AuditLog.create_event(event_attrs(%{source: "billing_api"}))
      AuditLog.create_event(event_attrs(%{source: "uptime_monitor"}))

      assert AuditLog.sources() == ["billing_api", "uptime_monitor"]
    end
  end
end
