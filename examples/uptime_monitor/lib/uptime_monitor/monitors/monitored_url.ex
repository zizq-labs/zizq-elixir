defmodule UptimeMonitor.Monitors.MonitoredUrl do
  @moduledoc """
  A URL being watched.

  A row is either **manual** — someone submitted it — or **sitemap**,
  meaning it was found inside another URL's sitemap. Sitemap-sourced
  rows carry the sitemap that produced them in `:source_sitemap_url`,
  which is what lets a re-scan reconcile them.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias UptimeMonitor.Monitors.Check

  @type t :: %__MODULE__{}

  @sources ~w(manual sitemap)
  @statuses ~w(up down)

  schema "monitored_urls" do
    field :url, :string
    field :source, :string, default: "manual"
    field :source_sitemap_url, :string
    field :enabled, :boolean, default: true
    # Reset to zero by a successful check, so it says how long the
    # current outage has run rather than how many times this URL has
    # ever failed.
    field :consecutive_failures, :integer, default: 0
    field :last_checked_at, :utc_datetime_usec
    field :last_status, :string

    has_many :checks, Check, foreign_key: :monitored_url_id

    timestamps(type: :utc_datetime_usec)
  end

  @fields [
    :url,
    :source,
    :source_sitemap_url,
    :enabled,
    :consecutive_failures,
    :last_checked_at,
    :last_status
  ]

  @doc """
  Cast and validate a monitored URL.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(monitored_url, attrs) do
    monitored_url
    |> cast(attrs, @fields)
    |> update_change(:url, &String.trim/1)
    |> validate_required([:url])
    |> validate_inclusion(:source, @sources)
    |> validate_inclusion(:last_status, @statuses)
    |> validate_url(:url)
    |> unique_constraint(:url,
      name: :monitored_urls_url_scoped_index,
      message: "is already being monitored"
    )
  end

  @doc """
  The sources a row can have.
  """
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc """
  The statuses a check can record.
  """
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  # Only http(s), and only with a host. Without this a probe would
  # happily be scheduled for "file:///etc/passwd" or a bare word that
  # `URI.parse/1` accepts and no request can be made from.
  defp validate_url(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case URI.parse(value) do
        %URI{scheme: scheme, host: host}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        _otherwise ->
          [{field, "must be an http:// or https:// URL"}]
      end
    end)
  end
end
