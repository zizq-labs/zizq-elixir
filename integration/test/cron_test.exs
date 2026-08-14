# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.Integration.CronTest do
  @moduledoc """
  Cron groups against a real server.

  The case that matters is the one an application makes on boot:
  `replace_cron/2` run repeatedly has to converge on the schedule it
  was given rather than accumulate, and that is only observable
  against a server that remembers the last call.
  """

  use ExUnit.Case, async: false

  # Cron is a Pro feature; `test_helper.exs` excludes this tag when the
  # server has no licence.
  @moduletag :pro

  setup do
    url = System.fetch_env!("ZIZQ_URL")
    start_supervised!({Zizq, name: :cron, url: url})

    # No `on_exit` cleanup: ExUnit stops supervised processes *before*
    # on_exit callbacks run, so the client would already be gone and
    # every test would end in a spurious failure. Nothing needs
    # cleaning up anyway — each test names its own group, and the
    # harness gives the server a fresh root directory per run.
    %{
      url: url,
      group: "cron_#{System.unique_integer([:positive])}",
      queue: "cronq_#{System.unique_integer([:positive])}"
    }
  end

  defp entry(ctx, name, opts \\ []) do
    [
      name: name,
      expression: Keyword.get(opts, :expression, "0 3 * * *"),
      job: [type: "cron_job", queue: ctx.queue, payload: Keyword.get(opts, :payload, %{})]
    ]
    |> Keyword.merge(Keyword.take(opts, [:timezone, :paused]))
  end

  defp install!(ctx, entries, opts \\ []) do
    ctx.group
    |> Zizq.Cron.new(Keyword.put(opts, :entries, entries))
    |> Zizq.replace_cron!(:cron)
  end

  test "installs a group and reads it back", ctx do
    installed = install!(ctx, [entry(ctx, "nightly", payload: %{"scope" => "all"})])

    assert installed.name == ctx.group
    assert installed.paused == false

    fetched = Zizq.get_cron!(ctx.group, :cron)
    assert [scheduled] = fetched.entries

    assert scheduled.name == "nightly"
    assert scheduled.expression == "0 3 * * *"
    assert scheduled.job.type == "cron_job"
    assert scheduled.job.queue == ctx.queue
    assert scheduled.job.payload == %{"scope" => "all"}
  end

  # The property the startup use case depends on: running it again
  # with the same schedule must leave the same schedule.
  test "replacing is idempotent", ctx do
    entries = [entry(ctx, "a"), entry(ctx, "b")]

    first = install!(ctx, entries)
    second = install!(ctx, entries)

    assert Enum.map(first.entries, & &1.name) == Enum.map(second.entries, & &1.name)
    assert length(Zizq.get_cron!(ctx.group, :cron).entries) == 2
  end

  # And the other half: what is sent is the whole schedule, so an
  # entry dropped from the list is dropped from the server.
  test "entries left out are removed", ctx do
    install!(ctx, [entry(ctx, "a"), entry(ctx, "b")])
    install!(ctx, [entry(ctx, "a")])

    assert [%{name: "a"}] = Zizq.get_cron!(ctx.group, :cron).entries
  end

  test "an existing entry can be rescheduled in place", ctx do
    install!(ctx, [entry(ctx, "a", expression: "0 3 * * *")])

    install!(ctx, [entry(ctx, "a", expression: "*/5 * * * *")])

    assert [scheduled] = Zizq.get_cron!(ctx.group, :cron).entries
    assert scheduled.expression == "*/5 * * * *"
  end

  test "an empty schedule empties the group without removing it", ctx do
    install!(ctx, [entry(ctx, "a")])

    assert %Zizq.Cron{entries: []} = install!(ctx, [])
    assert ctx.group in Zizq.list_crons!(:cron)
  end

  test "a timezone survives the round trip", ctx do
    install!(ctx, [entry(ctx, "a", timezone: "Australia/Melbourne")])

    assert [scheduled] = Zizq.get_cron!(ctx.group, :cron).entries
    assert scheduled.timezone == "Australia/Melbourne"
  end

  test "the server works out when the entry fires next", ctx do
    install!(ctx, [entry(ctx, "a", expression: "*/5 * * * *")])

    assert [scheduled] = Zizq.get_cron!(ctx.group, :cron).entries
    assert %DateTime{} = scheduled.next_enqueue_at
    assert DateTime.compare(scheduled.next_enqueue_at, DateTime.utc_now()) == :gt
  end

  test "a group appears in the listing, and goes when deleted", ctx do
    install!(ctx, [entry(ctx, "a")])
    assert ctx.group in Zizq.list_crons!(:cron)

    assert Zizq.delete_cron(ctx.group, :cron) == :ok
    refute ctx.group in Zizq.list_crons!(:cron)
    assert {:error, %Zizq.Error{reason: :not_found}} = Zizq.get_cron(ctx.group, :cron)
  end

  test "pausing and resuming a group", ctx do
    install!(ctx, [entry(ctx, "a")])

    assert {:ok, %Zizq.Cron{paused: true}} = Zizq.pause_cron(ctx.group, :cron)
    assert Zizq.get_cron!(ctx.group, :cron).paused == true

    assert {:ok, %Zizq.Cron{paused: false}} = Zizq.resume_cron(ctx.group, :cron)
    assert Zizq.get_cron!(ctx.group, :cron).paused == false
  end

  test "an entry can be installed already paused", ctx do
    install!(ctx, [entry(ctx, "a", paused: true)])

    assert [scheduled] = Zizq.get_cron!(ctx.group, :cron).entries
    assert scheduled.paused == true
  end

  # The loop the struct exists for: what the server returns can go
  # straight back to it, amended.
  test "a schedule can be read, amended and put back", ctx do
    install!(ctx, [entry(ctx, "a"), entry(ctx, "b")])

    Zizq.get_cron!(ctx.group, :cron)
    |> Zizq.Cron.delete_entry("a")
    |> Zizq.Cron.put_entry(entry(ctx, "c"))
    |> Zizq.replace_cron!(:cron)

    assert Enum.map(Zizq.get_cron!(ctx.group, :cron).entries, & &1.name) |> Enum.sort() ==
             ["b", "c"]
  end

  # Per entry, and it survives the round trip — which is exactly what
  # a group-level default could not do.
  test "an entry's timezone round-trips", ctx do
    install!(ctx, [
      entry(ctx, "a"),
      entry(ctx, "b", timezone: "Australia/Melbourne")
    ])

    entries = Zizq.get_cron!(ctx.group, :cron).entries

    assert Enum.find(entries, &(&1.name == "a")).timezone == nil
    assert Enum.find(entries, &(&1.name == "b")).timezone == "Australia/Melbourne"
  end

  describe "one entry at a time" do
    # Atomic on the server, unlike read-amend-replace, so it is the
    # safe way to suspend one job while an application is running.
    test "pausing and resuming leaves the rest alone", ctx do
      install!(ctx, [entry(ctx, "a"), entry(ctx, "b")])

      assert {:ok, paused} = Zizq.pause_cron_entry([cron: ctx.group, entry: "a"], :cron)
      assert paused.name == "a"
      assert paused.paused == true

      entries = Zizq.get_cron!(ctx.group, :cron).entries
      assert Enum.find(entries, &(&1.name == "a")).paused == true
      assert Enum.find(entries, &(&1.name == "b")).paused == false

      assert {:ok, %{paused: false}} =
               Zizq.resume_cron_entry([cron: ctx.group, entry: "a"], :cron)
    end

    test "deleting removes only that entry", ctx do
      install!(ctx, [entry(ctx, "a"), entry(ctx, "b")])

      assert Zizq.delete_cron_entry([cron: ctx.group, entry: "a"], :cron) == :ok

      assert Enum.map(Zizq.get_cron!(ctx.group, :cron).entries, & &1.name) == ["b"]
    end

    test "an entry that does not exist is :not_found", ctx do
      install!(ctx, [entry(ctx, "a")])

      assert {:error, %Zizq.Error{reason: :not_found}} =
               Zizq.delete_cron_entry([cron: ctx.group, entry: "absent"], :cron)
    end
  end

  test "a group that does not exist is :not_found", _ctx do
    assert {:error, %Zizq.Error{reason: :not_found}} = Zizq.get_cron("never_existed", :cron)
  end
end
