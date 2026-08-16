defmodule UptimeMonitor.Repo do
  use Ecto.Repo,
    otp_app: :uptime_monitor,
    adapter: Ecto.Adapters.SQLite3
end
