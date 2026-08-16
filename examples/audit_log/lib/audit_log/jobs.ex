# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule AuditLog.Jobs do
  @moduledoc """
  What this app consumes from Zizq, and how it dispatches it.
  """

  @queue "audit"

  @doc """
  The queue every producer writes `audit.create` jobs to.

  A queue is not declared anywhere on the server — it exists because a
  job named it — so this string is the only agreement needed between
  this app and its producers.
  """
  @spec queue() :: String.t()
  def queue, do: @queue

  @doc """
  The handler the worker runs.

  One route today. A router rather than a bare function so adding a
  second kind of audit job is a line here, not a restructure — and so
  an unrecognised type fails loudly instead of being swallowed.
  """
  @spec router() :: Zizq.Router.t()
  def router, do: Zizq.Router.new([AuditLog.Jobs.CreateEvent])
end
