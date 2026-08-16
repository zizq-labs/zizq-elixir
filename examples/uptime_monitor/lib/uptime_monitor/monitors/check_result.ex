defmodule UptimeMonitor.Monitors.CheckResult do
  @moduledoc """
  The outcome of probing a URL once.

  The prober's output and the only thing `Monitors.record_check/2`
  accepts, so what a probe produces and what the database stores stay
  described in one place. A struct rather than a bare map because the
  fields are fixed and a typo in one should not silently record a
  `nil`.
  """

  alias UptimeMonitor.Monitors.MonitoredUrl

  @type t :: %__MODULE__{
          status: String.t(),
          http_status: pos_integer() | nil,
          response_time_ms: non_neg_integer() | nil,
          final_url: String.t() | nil,
          error_message: String.t() | nil,
          sitemap?: boolean(),
          checked_at: DateTime.t()
        }

  @enforce_keys [:status, :checked_at]
  defstruct [
    :status,
    :http_status,
    :response_time_ms,
    :final_url,
    :error_message,
    :checked_at,
    sitemap?: false
  ]

  @doc """
  A successful probe.
  """
  @spec up(keyword()) :: t()
  def up(fields \\ []), do: new("up", fields)

  @doc """
  A failed probe. Anything that is not a 2xx final response, including
  a connection that never opened.
  """
  @spec down(keyword()) :: t()
  def down(fields \\ []), do: new("down", fields)

  defp new(status, fields) do
    unless status in MonitoredUrl.statuses() do
      raise ArgumentError, "unknown status: #{inspect(status)}"
    end

    struct!(
      __MODULE__,
      fields
      |> Keyword.put(:status, status)
      |> Keyword.put_new_lazy(:checked_at, &DateTime.utc_now/0)
    )
  end
end
