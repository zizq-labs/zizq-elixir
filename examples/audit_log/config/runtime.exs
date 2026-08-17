import Config

# Runtime rather than compile time, so the environment a container is
# started with is the one that takes effect — `config.exs` would bake
# whatever was set when the app was compiled.
if config_env() != :test do
  # `:inet` wants an address as a tuple, not a string. Parsing here
  # rather than at the call site means a typo fails at boot, naming
  # the variable, instead of surfacing as an obscure listener error.
  web_bind =
    case System.get_env("BIND") do
      nil ->
        {127, 0, 0, 1}

      address ->
        case address |> String.to_charlist() |> :inet.parse_address() do
          {:ok, ip} ->
            ip

          {:error, _reason} ->
            raise "BIND must be an IP address, e.g. 0.0.0.0 or ::, got: #{inspect(address)}"
        end
    end

  config :audit_log, web_bind: web_bind

  config :audit_log, AuditLog.Repo,
    database: System.get_env("DATABASE_PATH") || "storage/#{config_env()}.sqlite3"

  # TLS is opt-in: set none of these and the client connects exactly as
  # it did before. Each may be the PEM contents or a path to a file.
  zizq_tls =
    [
      ca: System.get_env("ZIZQ_TLS_CA"),
      client_cert: System.get_env("ZIZQ_TLS_CLIENT_CERT"),
      client_key: System.get_env("ZIZQ_TLS_CLIENT_KEY")
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)

  config :audit_log,
    zizq_url: System.get_env("ZIZQ_URL") || "http://127.0.0.1:7890",
    zizq_tls: zizq_tls,
    worker_concurrency: String.to_integer(System.get_env("ZIZQ_WORKER_CONCURRENCY") || "25"),
    web_port: String.to_integer(System.get_env("PORT") || "3000"),
    # Web and worker are separate roles so they can be scaled
    # independently, which is the shape a real deployment takes.
    # Both run in one node by default, for convenience.
    start_web?: System.get_env("START_WEB") != "0",
    start_zizq?: System.get_env("START_WORKER") != "0"
end
