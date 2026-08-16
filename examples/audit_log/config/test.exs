import Config

config :audit_log, AuditLog.Repo,
  database: "storage/test.sqlite3",
  pool: Ecto.Adapters.SQL.Sandbox,
  # SQLite permits one writer at a time, so a larger pool would only
  # produce `database is locked` under any real concurrency.
  pool_size: 1

config :audit_log, start_zizq?: false

config :logger, level: :warning
