# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Config.Owner do
  @moduledoc false
  # Ties the lifetime of a stored config to the client's supervision
  # tree. Without this, a stopped client would leave its config behind
  # and `Zizq.Config.fetch!/1` would keep answering for a client that
  # is no longer running, turning a clear "not started" error into a
  # confusing connection failure.
  #
  # Listed first among the supervisor's children so it terminates last,
  # keeping the config readable while Finch shuts down.

  use GenServer

  @doc false
  def start_link(%Zizq.Config{} = config) do
    GenServer.start_link(__MODULE__, config)
  end

  @impl GenServer
  def init(config) do
    Process.flag(:trap_exit, true)
    Zizq.Config.put(config)
    {:ok, config}
  end

  @impl GenServer
  def terminate(_reason, config) do
    Zizq.Config.delete(config.name)
    :ok
  end
end
