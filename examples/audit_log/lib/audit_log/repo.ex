# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule AuditLog.Repo do
  @moduledoc """
  The audit database.

  SQLite, because this example should run with nothing installed. The
  shape of the app would not change with Postgres behind it.
  """

  use Ecto.Repo,
    otp_app: :audit_log,
    adapter: Ecto.Adapters.SQLite3
end
