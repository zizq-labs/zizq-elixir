defmodule UptimeMonitor.Repo.Migrations.CreateMonitoredUrlsAndChecks do
  use Ecto.Migration

  def change do
    create table(:monitored_urls) do
      add :url, :string, null: false
      # "manual" for one someone submitted, "sitemap" for one
      # discovered inside another URL's sitemap.
      add :source, :string, null: false, default: "manual"
      # The sitemap that produced this row, for sitemap-sourced URLs.
      add :source_sitemap_url, :string
      add :enabled, :boolean, null: false, default: true
      add :consecutive_failures, :integer, null: false, default: 0
      add :last_checked_at, :utc_datetime_usec
      add :last_status, :string

      timestamps(type: :utc_datetime_usec)
    end

    # A URL can be monitored once on its own account and once per
    # sitemap that lists it. SQLite treats two NULLs as distinct, so
    # the scope is coalesced to '' to make manual rows collide.
    create unique_index(:monitored_urls, ["url", "COALESCE(source_sitemap_url, '')"],
             name: :monitored_urls_url_scoped_index
           )

    create index(:monitored_urls, [:source_sitemap_url])

    create table(:checks) do
      add :monitored_url_id, references(:monitored_urls, on_delete: :delete_all), null: false
      add :checked_at, :utc_datetime_usec, null: false
      add :status, :string, null: false
      add :http_status, :integer
      add :response_time_ms, :integer
      add :final_url, :string
      add :error_message, :text

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:checks, [:monitored_url_id, :checked_at])
  end
end
