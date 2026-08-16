import Config

# Runtime rather than compile time, so the environment a container is
# started with is the one that takes effect — `config.exs` would bake
# whatever was set when the app was compiled.
if config_env() != :test do
  config :audit_log, AuditLog.Repo,
    database: System.get_env("DATABASE_PATH") || "storage/#{config_env()}.sqlite3"

  config :audit_log,
    zizq_url: System.get_env("ZIZQ_URL") || "http://127.0.0.1:7890",
    worker_concurrency: String.to_integer(System.get_env("ZIZQ_WORKER_CONCURRENCY") || "25")
end
