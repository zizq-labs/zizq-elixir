import Config

config :audit_log, ecto_repos: [AuditLog.Repo]

config :audit_log, AuditLog.Repo,
  database: System.get_env("DATABASE_PATH") || "storage/#{config_env()}.sqlite3",
  # WAL lets the web process read while the worker writes. Without it
  # SQLite locks the whole file for the duration of a write.
  journal_mode: :wal,
  # SQLite serialises writes anyway, so a deep pool buys nothing and
  # just moves contention from the pool to the file lock.
  pool_size: 5

config :logger, :console, format: "$time [$level] $message\n"

# Only the test environment needs to override anything, so there
# are no empty dev/prod config files sitting here to imply otherwise.
if config_env() == :test do
  import_config "test.exs"
end
