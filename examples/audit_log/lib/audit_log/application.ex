# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule AuditLog.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [AuditLog.Repo | zizq_children()]

    Supervisor.start_link(children, strategy: :one_for_one, name: AuditLog.Supervisor)
  end

  # The test suite runs handlers directly through `Zizq.Testing`, so it
  # sets `start_zizq?: false` and needs no server to talk to.
  defp zizq_children do
    if Application.get_env(:audit_log, :start_zizq?, true) do
      [
        {Zizq, name: AuditLog.Zizq, url: Application.fetch_env!(:audit_log, :zizq_url)},
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
end
