defmodule UptimeMonitor.Jobs do
  @moduledoc """
  What this app enqueues and consumes.

  Unlike the audit log — a pure sink — this app is both producer and
  consumer of its own jobs, so the job modules declare enqueue
  defaults and the router registers them for the worker.
  """

  @queue "uptime_monitor"

  @doc """
  The queue this app's own jobs live on.
  """
  @spec queue() :: String.t()
  def queue, do: @queue

  @doc """
  The handler the worker runs.
  """
  @spec router() :: Zizq.Router.t()
  def router, do: Zizq.Router.new([UptimeMonitor.Jobs.CheckUrl])
end
