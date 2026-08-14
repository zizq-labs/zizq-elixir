# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Integration.EraseTest do
  @moduledoc """
  Emptying the server.

  Deliberately last-ish and `async: false`, like the rest of this
  suite: it removes everything, so nothing else may be mid-scenario
  while it runs.
  """

  use ExUnit.Case, async: false

  setup do
    url = System.fetch_env!("ZIZQ_URL")
    start_supervised!({Zizq, name: :erase, url: url})

    %{url: url, queue: "erase_#{System.unique_integer([:positive])}"}
  end

  test "removes every job, whatever queue it is on", ctx do
    for queue <- [ctx.queue, "#{ctx.queue}_other"] do
      Zizq.enqueue!([type: "erase", queue: queue], :erase)
    end

    assert Zizq.count_jobs!(:erase) > 0

    assert Zizq.erase_all_data(:erase) == :ok

    assert Zizq.count_jobs!(:erase) == 0
  end

  # The reason it is one endpoint rather than two calls: jobs and
  # schedules go together, so nothing can be enqueued in between.
  @tag :pro
  test "removes cron schedules too", ctx do
    group = "erase_cron_#{System.unique_integer([:positive])}"

    Zizq.Cron.new(group,
      entries: [
        [name: "a", expression: "0 3 * * *", job: [type: "erase", queue: ctx.queue]]
      ]
    )
    |> Zizq.replace_cron!(:erase)

    assert group in Zizq.list_crons!(:erase)

    assert Zizq.erase_all_data(:erase) == :ok

    refute group in Zizq.list_crons!(:erase)
    assert Zizq.list_crons!(:erase) == []
  end

  test "an already-empty server is fine", _ctx do
    assert Zizq.erase_all_data(:erase) == :ok
    assert Zizq.erase_all_data(:erase) == :ok
    assert Zizq.count_jobs!(:erase) == 0
  end

  # Jobs are gone, not merely hidden — a listing and a count agree.
  test "what it removes stays removed", ctx do
    job = Zizq.enqueue!([type: "erase", queue: ctx.queue], :erase)

    assert Zizq.erase_all_data(:erase) == :ok

    assert {:error, %Zizq.Error{reason: :not_found}} = Zizq.get_job(job.id, :erase)
    assert Zizq.list_jobs!(:erase).jobs == []
  end
end
