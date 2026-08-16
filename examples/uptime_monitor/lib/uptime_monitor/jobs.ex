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
  The name of the Zizq client this app enqueues through.

  Named in one place so a handler that enqueues follow-up work does
  not hardcode it, and the test suite can point the same name at
  `Zizq.Testing`'s recorder.
  """
  @spec client() :: atom()
  def client, do: UptimeMonitor.Zizq

  @doc """
  The handler the worker runs.
  """
  @spec router() :: Zizq.Router.t()
  def router do
    Zizq.Router.new([
      UptimeMonitor.Jobs.CheckUrl,
      UptimeMonitor.Jobs.DiscoverSitemapUrls
    ])
  end
end
