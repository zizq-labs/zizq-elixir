# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :uptime_monitor,
  ecto_repos: [UptimeMonitor.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :uptime_monitor, UptimeMonitorWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: UptimeMonitorWeb.ErrorHTML, json: UptimeMonitorWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: UptimeMonitor.PubSub,
  live_view: [signing_salt: "9xb5sXRd"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  uptime_monitor: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

# Zizq: where the server is, and how many jobs run at once.
config :uptime_monitor,
  start_zizq?: true,
  zizq_url: "http://127.0.0.1:7890",
  worker_concurrency: 25
