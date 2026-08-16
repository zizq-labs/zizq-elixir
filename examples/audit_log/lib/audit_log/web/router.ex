# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule AuditLog.Web.Router do
  @moduledoc """
  The read-only audit feed.

  Deliberately small: one page, no framework. The web tier never
  enqueues and never runs a job — it reads what the worker wrote.
  """

  use Plug.Router

  alias AuditLog.Jobs
  alias AuditLog.Web.View

  @page_size 50

  plug Plug.Static, at: "/", from: {:audit_log, "priv/static"}, only: ~w(styles.css)
  plug :match
  plug :fetch_query_params
  plug :dispatch

  get "/" do
    source = presence(conn.params["source"])
    cursor = decode_cursor(conn.params["cursor"])

    events = AuditLog.recent(limit: @page_size, source: source, before: cursor)

    html =
      View.index(%{
        events: events,
        queue: Jobs.queue(),
        source: source,
        sources: AuditLog.sources(),
        has_cursor: cursor != nil,
        next_cursor: next_cursor(events),
        newest_path: path(source, nil),
        next_path: path(source, next_cursor(events))
      })

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  get "/up" do
    send_resp(conn, 200, "ok")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # --- Pagination ---
  #
  # The cursor is `<epoch_micros>:<id>`, matching the other clients'
  # audit examples so a URL means the same thing in each. Microseconds
  # because that is the column's resolution — truncating to seconds
  # would make the cursor ambiguous exactly when events arrive in
  # bursts, which for an audit feed is most of the time.

  defp next_cursor(events) when length(events) < @page_size, do: nil

  defp next_cursor(events) do
    {at, id} = events |> List.last() |> AuditLog.cursor()

    "#{DateTime.to_unix(at, :microsecond)}:#{id}"
  end

  defp decode_cursor(nil), do: nil

  defp decode_cursor(cursor) do
    with [micros, id] <- String.split(cursor, ":", parts: 2),
         {micros, ""} <- Integer.parse(micros),
         {id, ""} <- Integer.parse(id),
         {:ok, at} <- DateTime.from_unix(micros, :microsecond) do
      {at, id}
    else
      # A cursor is user input. A malformed one shows the first page
      # rather than raising a 500 at someone editing a URL.
      _ -> nil
    end
  end

  defp path(source, cursor) do
    params =
      [source: source, cursor: cursor]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case params do
      [] -> "/"
      params -> "/?" <> URI.encode_query(params)
    end
  end

  defp presence(nil), do: nil

  defp presence(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
