defmodule UptimeMonitor.Monitors.Check do
  @moduledoc """
  One recorded probe of a monitored URL.

  Checks accumulate — a row per probe — so the history of an outage
  survives after the URL comes back up.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias UptimeMonitor.Monitors.MonitoredUrl

  @type t :: %__MODULE__{}

  schema "checks" do
    field :checked_at, :utc_datetime_usec
    field :status, :string
    field :http_status, :integer
    field :response_time_ms, :integer
    field :final_url, :string
    field :error_message, :string

    belongs_to :monitored_url, MonitoredUrl

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @fields [
    :monitored_url_id,
    :checked_at,
    :status,
    :http_status,
    :response_time_ms,
    :final_url,
    :error_message
  ]

  @doc """
  Cast and validate a recorded check.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(check, attrs) do
    check
    |> cast(attrs, @fields)
    |> validate_required([:monitored_url_id, :checked_at, :status])
    |> validate_inclusion(:status, MonitoredUrl.statuses())
    |> assoc_constraint(:monitored_url)
  end
end
