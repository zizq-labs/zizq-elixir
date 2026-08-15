# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule AuditLog.AuditEventTest do
  use AuditLog.DataCase

  describe "changeset/2" do
    test "accepts the three required fields" do
      changeset = AuditEvent.changeset(%AuditEvent{}, event_attrs())

      assert changeset.valid?
    end

    test "requires occurred_at, source and event_type" do
      changeset = AuditEvent.changeset(%AuditEvent{}, %{})

      assert %{
               occurred_at: ["can't be blank"],
               source: ["can't be blank"],
               event_type: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "everything else is optional" do
      changeset = AuditEvent.changeset(%AuditEvent{}, event_attrs())

      assert changeset.valid?
      assert get_field(changeset, :actor) == nil
      assert get_field(changeset, :data) == nil
    end

    test "keeps structured data as a map" do
      attrs = event_attrs(%{data: %{"amount_cents" => 2400, "currency" => "AUD"}})

      changeset = AuditEvent.changeset(%AuditEvent{}, attrs)

      assert get_field(changeset, :data) == %{"amount_cents" => 2400, "currency" => "AUD"}
    end

    # ISO8601 is the agreed wire format for a timestamp across every
    # Zizq example app, so it is the only one accepted.
    test "parses an ISO8601 occurred_at" do
      changeset =
        AuditEvent.changeset(%AuditEvent{}, event_attrs(%{occurred_at: "2026-08-15T10:15:00Z"}))

      assert changeset.valid?
      assert get_field(changeset, :occurred_at) == ~U[2026-08-15 10:15:00.000000Z]
    end

    test "normalises an offset to UTC" do
      changeset =
        AuditEvent.changeset(
          %AuditEvent{},
          event_attrs(%{occurred_at: "2026-08-15T20:15:00+10:00"})
        )

      assert get_field(changeset, :occurred_at) == ~U[2026-08-15 10:15:00.000000Z]
    end

    # A producer sending epoch integers should find out, rather than
    # have this consumer guess at seconds-versus-milliseconds while
    # another consumer rejects it.
    test "rejects a non-ISO8601 occurred_at" do
      for value <- [1_786_788_900, 1_786_788_900_000, "yesterday", "2026-08-15", %{"a" => 1}] do
        changeset = AuditEvent.changeset(%AuditEvent{}, event_attrs(%{occurred_at: value}))

        refute changeset.valid?, "expected #{inspect(value)} to be rejected"
        assert %{occurred_at: ["is invalid"]} = errors_on(changeset)
      end
    end

    # Absent and malformed are different mistakes, and say so.
    test "distinguishes a missing timestamp from an invalid one" do
      missing = AuditEvent.changeset(%AuditEvent{}, event_attrs(%{occurred_at: nil}))
      invalid = AuditEvent.changeset(%AuditEvent{}, event_attrs(%{occurred_at: "nope"}))

      assert %{occurred_at: ["can't be blank"]} = errors_on(missing)
      assert %{occurred_at: ["is invalid"]} = errors_on(invalid)
    end
  end

  describe "from_payload/1" do
    test "maps a producer's payload onto the schema's fields" do
      attrs =
        AuditEvent.from_payload(%{
          "occurred_at" => "2026-08-15T10:15:00Z",
          "source" => "uptime_monitor",
          "event_type" => "url.status.changed",
          "actor" => "system",
          "ip" => "203.0.113.7",
          "resource" => "monitored_url:42",
          "text" => "https://example.com went down",
          "data" => %{"from" => "up", "to" => "down"}
        })

      # Renamed, not parsed — the changeset casts it.
      assert attrs.occurred_at == "2026-08-15T10:15:00Z"
      assert attrs.source == "uptime_monitor"
      assert attrs.event_type == "url.status.changed"
      assert attrs.actor == "system"
      assert attrs.ip == "203.0.113.7"
      assert attrs.resource == "monitored_url:42"
      assert attrs.text == "https://example.com went down"
      assert attrs.data == %{"from" => "up", "to" => "down"}
    end

    test "leaves absent optional fields nil" do
      attrs =
        AuditEvent.from_payload(%{
          "occurred_at" => "2026-08-15T10:15:00Z",
          "source" => "billing_api",
          "event_type" => "invoice.refunded"
        })

      assert attrs.actor == nil
      assert attrs.data == nil
    end

    # Nothing is interpreted here, so a malformed value reaches the
    # changeset intact and is reported against its field rather than
    # raising a MatchError from inside the job handler.
    test "passes values through untouched for the changeset to judge" do
      assert %{occurred_at: "yesterday"} =
               AuditEvent.from_payload(%{"occurred_at" => "yesterday"})

      assert %{occurred_at: %{"a" => 1}} =
               AuditEvent.from_payload(%{"occurred_at" => %{"a" => 1}})

      assert %{occurred_at: nil} = AuditEvent.from_payload(%{})
    end

    test "an event built from a payload missing its required fields is invalid" do
      changeset =
        %{"source" => "billing_api"}
        |> AuditEvent.from_payload()
        |> then(&AuditEvent.changeset(%AuditEvent{}, &1))

      refute changeset.valid?

      assert %{occurred_at: ["can't be blank"], event_type: ["can't be blank"]} =
               errors_on(changeset)
    end
  end
end
