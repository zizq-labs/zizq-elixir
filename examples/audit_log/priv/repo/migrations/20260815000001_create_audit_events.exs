defmodule AuditLog.Repo.Migrations.CreateAuditEvents do
  use Ecto.Migration

  def change do
    create table(:audit_events) do
      add :occurred_at, :utc_datetime_usec, null: false
      # The system that produced the event, e.g. "uptime_monitor". A
      # string rather than an enum: the sink stays ignorant of which
      # systems integrate with it, which is the whole point.
      add :source, :string, null: false
      # Stored, never switched on.
      add :event_type, :string, null: false
      add :actor, :string
      add :ip, :string
      add :resource, :string
      add :text, :text
      # Structured payload, serialised as JSON by the adapter.
      add :data, :map

      add :created_at, :utc_datetime_usec, null: false
    end

    # The feed is most-recent-first. The trailing id breaks ties, so
    # (occurred_at, id) totally orders the table and keyset pagination
    # cannot skip or repeat a row when timestamps collide.
    create index(:audit_events, [:occurred_at, :id])

    # The same feed, narrowed to one producer.
    create index(:audit_events, [:source, :occurred_at, :id])
  end
end
