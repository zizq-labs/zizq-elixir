# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule AuditLog do
  @moduledoc """
  Reading and writing audit events.

  Everything that touches the database goes through here, so the job
  handler and the web feed share one vocabulary and neither builds a
  query of its own.
  """

  import Ecto.Query

  alias AuditLog.AuditEvent
  alias AuditLog.Repo

  @default_limit 50

  @doc """
  Store an event from a map of attributes.
  """
  @spec create_event(map()) :: {:ok, AuditEvent.t()} | {:error, Ecto.Changeset.t()}
  def create_event(attrs) do
    %AuditEvent{}
    |> AuditEvent.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Store an event from an `audit.create` job payload.

  This is what the job handler calls. Returns the same tuple
  `create_event/1` does, so an invalid payload is a value to act on
  rather than an exception.
  """
  @spec record_payload(map()) :: {:ok, AuditEvent.t()} | {:error, Ecto.Changeset.t()}
  def record_payload(payload) when is_map(payload) do
    payload
    |> AuditEvent.from_payload()
    |> create_event()
  end

  @doc """
  One page of the feed, most recent first.

  ## Options

    * `:limit` — how many events. Defaults to #{@default_limit}.
    * `:source` — only events from this producer.
    * `:before` — a `{occurred_at, id}` cursor from `cursor/1`,
      returning the events that follow it.
  """
  @spec recent(keyword()) :: [AuditEvent.t()]
  def recent(opts \\ []) do
    AuditEvent
    |> order_by([e], desc: e.occurred_at, desc: e.id)
    |> limit(^Keyword.get(opts, :limit, @default_limit))
    |> filter_source(Keyword.get(opts, :source))
    |> after_cursor(Keyword.get(opts, :before))
    |> Repo.all()
  end

  @doc """
  The cursor identifying an event's position in the feed.

  Keyset rather than an offset, so a page cannot shift under a reader
  while events keep arriving — which, for an audit feed, they do.
  """
  @spec cursor(AuditEvent.t()) :: {DateTime.t(), integer()}
  def cursor(%AuditEvent{occurred_at: at, id: id}), do: {at, id}

  @doc """
  How many events are stored, optionally narrowed to one producer.
  """
  @spec count_events(keyword()) :: non_neg_integer()
  def count_events(opts \\ []) do
    AuditEvent
    |> filter_source(Keyword.get(opts, :source))
    |> Repo.aggregate(:count)
  end

  @doc """
  A changeset's errors as one readable line.

  The job handler puts this in the reason it cancels with, so the
  message stored against the dead job names the fields the producer
  got wrong rather than being an inspected struct.

      "occurred_at can't be blank; source can't be blank"
  """
  @spec describe_errors(Ecto.Changeset.t()) :: String.t()
  def describe_errors(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
        opts |> Keyword.get(String.to_existing_atom(key), "") |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  @doc """
  Fetch one event, or `nil`.
  """
  @spec get_event(integer()) :: AuditEvent.t() | nil
  def get_event(id), do: Repo.get(AuditEvent, id)

  @doc """
  The producers that have sent events, alphabetically.
  """
  @spec sources() :: [String.t()]
  def sources do
    AuditEvent
    |> select([e], e.source)
    |> distinct(true)
    |> order_by([e], asc: e.source)
    |> Repo.all()
  end

  defp filter_source(query, nil), do: query
  defp filter_source(query, ""), do: query
  defp filter_source(query, source), do: where(query, [e], e.source == ^source)

  defp after_cursor(query, nil), do: query

  # Spelled out rather than as a row-value comparison, which SQLite
  # supports but not every adapter does.
  defp after_cursor(query, {at, id}) do
    where(query, [e], e.occurred_at < ^at or (e.occurred_at == ^at and e.id < ^id))
  end
end
