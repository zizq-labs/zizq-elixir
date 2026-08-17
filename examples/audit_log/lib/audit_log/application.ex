# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule AuditLog.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children = [AuditLog.Repo] ++ zizq_children() ++ web_children()

    Supervisor.start_link(children, strategy: :one_for_one, name: AuditLog.Supervisor)
  end

  # Web and worker are separate roles, so a deployment can scale them
  # apart. Both run here by default because one command is friendlier
  # to try. The test suite runs handlers directly through
  # `Zizq.Testing` and calls the router with `Plug.Test`, so it starts
  # neither.
  defp zizq_children do
    if Application.get_env(:audit_log, :start_zizq?, true) do
      Logger.info("[audit_log] worker draining #{AuditLog.Jobs.queue()}")

      [
        {Zizq,
         name: AuditLog.Zizq,
         url: Application.fetch_env!(:audit_log, :zizq_url),
         tls: Application.get_env(:audit_log, :zizq_tls, [])},
        {Zizq.Worker,
         client: AuditLog.Zizq,
         queues: [AuditLog.Jobs.queue()],
         concurrency: Application.fetch_env!(:audit_log, :worker_concurrency),
         handler: AuditLog.Jobs.router()}
      ]
    else
      []
    end
  end

  defp web_children do
    if Application.get_env(:audit_log, :start_web?, true) do
      bind = Application.fetch_env!(:audit_log, :web_bind)
      port = Application.fetch_env!(:audit_log, :web_port)

      Logger.info("[audit_log] web listening on http://#{:inet.ntoa(bind)}:#{port}")

      [{Bandit, plug: AuditLog.Web.Router, ip: bind, port: port}]
    else
      []
    end
  end
end
