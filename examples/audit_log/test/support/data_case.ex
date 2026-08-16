# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule AuditLog.DataCase do
  @moduledoc """
  A case template for tests that touch the database.

  Each test runs inside a sandboxed transaction that is rolled back
  afterwards, so tests neither see each other's rows nor need to clean
  up after themselves.

  Cases are **not** `async: true`. SQLite permits one writer at a
  time, so concurrent cases would contend on the file lock rather than
  run in parallel — the pool is sized to one for the same reason.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Ecto.Changeset
      import Ecto.Query
      import AuditLog.DataCase

      alias AuditLog.AuditEvent
      alias AuditLog.Repo
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(AuditLog.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc """
  The error messages on a changeset, keyed by field.

      assert %{occurred_at: ["can't be blank"]} = errors_on(changeset)
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
        opts |> Keyword.get(String.to_existing_atom(key), "") |> to_string()
      end)
    end)
  end

  @doc """
  Attributes for a valid event, merged with any overrides.
  """
  def event_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        occurred_at: DateTime.utc_now(),
        source: "billing_api",
        event_type: "invoice.refunded"
      },
      Map.new(overrides)
    )
  end
end
