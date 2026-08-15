# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule AuditLog.AuditEvent do
  @moduledoc """
  One recorded audit event.

  The audit log is a *sink*: it stores what producers send it and does
  not interpret `:event_type`. Only the three fields a producer must
  agree to supply are validated — everything else is optional, and
  what it means is the producer's business.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "audit_events" do
    # When the event happened at the source, which is not when we
    # stored it — a producer may have queued it long before.
    field :occurred_at, :utc_datetime_usec
    field :source, :string
    field :event_type, :string
    field :actor, :string
    field :ip, :string
    field :resource, :string
    field :text, :string
    field :data, :map

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false)
  end

  @fields [:occurred_at, :source, :event_type, :actor, :ip, :resource, :text, :data]
  @required [:occurred_at, :source, :event_type]

  @doc """
  Cast and validate attributes into a changeset.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, @fields)
    |> validate_required(@required)
    |> validate_length(:source, max: 255)
    |> validate_length(:event_type, max: 255)
  end

  @doc """
  Build attributes from an `audit.create` job payload.

  The payload is plain JSON with string keys, since it arrives from a
  producer that shares no code with this app — and may not even be
  written in Elixir. This only renames the keys; `changeset/2` does
  the validating, so a bad value is reported against its field rather
  than raised from inside the handler.

  `occurred_at` must be an **ISO8601** timestamp, which is what every
  Zizq example app emits. `cast/3` parses it, so an epoch integer or
  anything else unparseable comes back as `occurred_at: ["is
  invalid"]` instead of being guessed at.
  """
  @spec from_payload(map()) :: map()
  def from_payload(payload) when is_map(payload) do
    %{
      occurred_at: payload["occurred_at"],
      source: payload["source"],
      event_type: payload["event_type"],
      actor: payload["actor"],
      ip: payload["ip"],
      resource: payload["resource"],
      text: payload["text"],
      data: payload["data"]
    }
  end
end
