# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule AuditLog.Web.View do
  @moduledoc """
  The feed's HTML, rendered from an EEx template compiled into this
  module at build time.

  > #### EEx does not escape anything {: .warning}
  >
  > Unlike Phoenix's `~H`, plain EEx interpolates whatever you give
  > it. Every dynamic value in the template therefore goes through
  > `h/1` — and it must, because an audit event's text, source and
  > resource all arrive from producers this app does not control.
  """

  require EEx

  @template Path.join(__DIR__, "templates/index.html.eex")
  @external_resource @template

  EEx.function_from_file(:def, :index, @template, [:assigns])

  @doc """
  Escape a value for interpolation into HTML.
  """
  @spec h(term()) :: String.t()
  def h(nil), do: ""
  def h(value) when is_binary(value), do: Plug.HTML.html_escape(value)
  def h(value), do: value |> to_string() |> Plug.HTML.html_escape()

  @doc """
  A coarse "3m ago" for a timestamp.
  """
  @spec time_ago(DateTime.t() | nil) :: String.t()
  def time_ago(nil), do: ""

  def time_ago(%DateTime{} = at) do
    case DateTime.diff(DateTime.utc_now(), at, :second) do
      seconds when seconds < 0 -> DateTime.to_iso8601(at)
      seconds when seconds < 60 -> "#{seconds}s ago"
      seconds when seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds when seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      seconds -> "#{div(seconds, 86_400)}d ago"
    end
  end

  @doc """
  A producer's structured data, pretty-printed, or `""` when there is
  nothing worth showing.
  """
  @spec format_data(term()) :: String.t()
  def format_data(nil), do: ""
  def format_data(data) when data == %{}, do: ""
  def format_data(data), do: Jason.encode!(data, pretty: true)
end
