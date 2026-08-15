# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule AuditLog.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [AuditLog.Repo]

    Supervisor.start_link(children, strategy: :one_for_one, name: AuditLog.Supervisor)
  end
end
