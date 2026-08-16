defmodule UptimeMonitor.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        UptimeMonitorWeb.Telemetry,
        UptimeMonitor.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:uptime_monitor, :ecto_repos), skip: skip_migrations?()},
        {DNSCluster, query: Application.get_env(:uptime_monitor, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: UptimeMonitor.PubSub}
      ] ++ zizq_children() ++ [UptimeMonitorWeb.Endpoint]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: UptimeMonitor.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      install_cron()
      {:ok, pid}
    end
  end

  # After the tree is up, since it needs the client. Never fatal: a
  # server without a Pro licence refuses, and the app is still usable
  # without periodic re-checks.
  defp install_cron do
    if Application.get_env(:uptime_monitor, :start_zizq?, true) do
      UptimeMonitor.Cron.install()
    end
  end

  # The Zizq client and the worker that drains this app's own queue.
  # The test suite runs handlers directly through `Zizq.Testing`, so it
  # sets `start_zizq?: false` and needs no server to talk to.
  defp zizq_children do
    if Application.get_env(:uptime_monitor, :start_zizq?, true) do
      [
        {Zizq, name: UptimeMonitor.Zizq, url: Application.fetch_env!(:uptime_monitor, :zizq_url)},
        {Zizq.Worker,
         client: UptimeMonitor.Zizq,
         queues: [UptimeMonitor.Jobs.queue()],
         concurrency: Application.fetch_env!(:uptime_monitor, :worker_concurrency),
         handler: UptimeMonitor.Jobs.router()}
      ]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    UptimeMonitorWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
