# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.CronTest do
  @moduledoc """
  Installing and reading cron groups.

  `replace_cron/3` gets most of the attention: it is the call an
  application makes on every boot, so what it sends has to be the
  whole schedule and nothing incidental.
  """

  use ExUnit.Case, async: true

  alias Zizq.FakeServer

  defp server(status, body) do
    test_pid = self()

    FakeServer.start_client!(
      fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        decoded = if raw == "", do: nil, else: JSON.decode!(raw)
        send(test_pid, {:request, conn.method, conn.request_path, decoded})

        FakeServer.respond(conn, status, if(body, do: "application/json"), body || "")
      end,
      format: :json
    )
  end

  defp group(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "my_app",
        "paused" => false,
        "entries" => [
          %{
            "name" => "digest",
            "expression" => "*/15 * * * *",
            "paused" => false,
            "job" => %{"type" => "digest", "queue" => "reports", "payload" => %{}}
          }
        ]
      },
      overrides
    )
    |> JSON.encode!()
  end

  describe "replace_cron/3" do
    test "sends the whole schedule" do
      name = server(200, group())

      Zizq.Cron.new("my_app",
        entries: [
          [name: "digest", expression: "*/15 * * * *", job: [type: "digest", queue: "reports"]]
        ]
      )
      |> Zizq.replace_cron(name)

      assert_receive {:request, "PUT", "/crons/my_app", body}
      assert [entry] = body["entries"]
      assert entry["name"] == "digest"
      assert entry["expression"] == "*/15 * * * *"
      assert entry["job"]["type"] == "digest"
      assert entry["job"]["queue"] == "reports"
    end

    test "returns the group the server installed" do
      name = server(200, group())

      assert {:ok, %Zizq.Cron{name: "my_app", paused: false, entries: [entry]}} =
               Zizq.replace_cron(Zizq.Cron.new("my_app"), name)

      assert %Zizq.CronEntry{name: "digest", expression: "*/15 * * * *"} = entry
    end

    test "a job built from a module works as the template" do
      defmodule Digest do
        use Zizq.JobKind, type: "digest", queue: "reports"

        @impl Zizq.JobKind
        def perform(_payload), do: :ok
      end

      name = server(200, group())

      Zizq.Cron.new("my_app",
        entries: [[name: "digest", expression: "0 * * * *", job: Digest.new(%{"scope" => "all"})]]
      )
      |> Zizq.replace_cron(name)

      assert_receive {:request, "PUT", _, body}
      assert [%{"job" => job}] = body["entries"]
      assert job["type"] == "digest"
      assert job["queue"] == "reports"
      assert job["payload"] == %{"scope" => "all"}
    end

    test "optional entry fields are sent only when set" do
      name = server(200, group())

      Zizq.Cron.new("my_app",
        entries: [
          [name: "a", expression: "* * * * *", job: [type: "t"]],
          [
            name: "b",
            expression: "* * * * *",
            timezone: "Australia/Melbourne",
            paused: true,
            job: [type: "t"]
          ]
        ]
      )
      |> Zizq.replace_cron(name)

      assert_receive {:request, "PUT", _, body}
      [a, b] = body["entries"]

      refute Map.has_key?(a, "timezone")
      refute Map.has_key?(a, "paused")
      assert b["timezone"] == "Australia/Melbourne"
      assert b["paused"] == true
    end

    test "the group's paused state is sent only when given" do
      name = server(200, group())

      Zizq.replace_cron(Zizq.Cron.new("my_app"), name)
      assert_receive {:request, "PUT", _, body}
      refute Map.has_key?(body, "paused")

      Zizq.replace_cron(Zizq.Cron.new("my_app", paused: true), name)
      assert_receive {:request, "PUT", _, body}
      assert body["paused"] == true
    end

    # Applied dynamically because the raise below narrows the inferred
    # type to `%Zizq.Cron{name: binary()}`, so a direct call would be a
    # compile-time type warning about the very input under test.
    test "a schedule with no name cannot be installed" do
      name = server(200, group())

      assert_raise ArgumentError, ~r/no name/, fn ->
        apply(Zizq, :replace_cron, [%Zizq.Cron{entries: []}, name])
      end
    end

    test "an empty schedule is allowed, and explicit" do
      name = server(200, group(%{"entries" => []}))

      assert {:ok, %Zizq.Cron{entries: []}} = Zizq.replace_cron(Zizq.Cron.new("my_app"), name)
      assert_receive {:request, "PUT", _, %{"entries" => []}}
    end

    # The schedule decides when the job runs, so a template carrying
    # its own start time is two answers to one question.
    test "an entry's job cannot set ready_at" do
      assert_raise ArgumentError, ~r/cannot set :ready_at/, fn ->
        Zizq.Cron.new("my_app",
          entries: [
            [name: "a", expression: "* * * * *", job: [type: "t", ready_at: DateTime.utc_now()]]
          ]
        )
      end
    end

    # Validated as the schedule is built, so a malformed entry fails
    # without a client in sight — long before anything could be sent.
    test "an entry is validated when the schedule is built" do
      for {attrs, message} <- [
            {[expression: "* * * * *", job: [type: "t"]], ~r/:name is required/},
            {[name: "a", job: [type: "t"]], ~r/:expression is required/},
            {[name: "a", expression: "* * * * *"], ~r/:job is required/},
            {[name: "a", expression: "* * * * *", job: [type: "t"], nope: 1],
             ~r/unknown cron entry key/}
          ] do
        assert_raise ArgumentError, message, fn ->
          Zizq.Cron.new("my_app", entries: [attrs])
        end
      end
    end

    test "cron without a licence surfaces as :forbidden" do
      name = server(403, ~s({"error":"cron requires a Pro license"}))

      assert {:error, %Zizq.Error{reason: :forbidden}} =
               Zizq.replace_cron(Zizq.Cron.new("my_app"), name)
    end
  end

  describe "get_cron/2 and list_crons/1" do
    test "reads a group and decodes its entries" do
      name = server(200, group())

      assert {:ok, %Zizq.Cron{name: "my_app"} = cron} = Zizq.get_cron("my_app", name)
      assert_receive {:request, "GET", "/crons/my_app", _}

      assert %Zizq.CronEntry{job: %Zizq.Enqueue{type: "digest", queue: "reports"}} =
               Zizq.Cron.entry(cron, "digest")
    end

    test "entry/2 returns nil for a name that is not there" do
      name = server(200, group())

      {:ok, cron} = Zizq.get_cron("my_app", name)

      assert Zizq.Cron.entry(cron, "absent") == nil
    end

    test "a group that does not exist is :not_found" do
      name = server(404, ~s({"error":"no such cron"}))

      assert {:error, %Zizq.Error{reason: :not_found}} = Zizq.get_cron("absent", name)
    end

    test "lists group names" do
      name = server(200, ~s({"crons":["my_app","other"]}))

      assert Zizq.list_crons(name) == {:ok, ["my_app", "other"]}
      assert_receive {:request, "GET", "/crons", _}
    end
  end

  describe "building a schedule" do
    test "put_entry appends, and replaces by name" do
      cron =
        Zizq.Cron.new("my_app")
        |> Zizq.Cron.put_entry(name: "a", expression: "0 1 * * *", job: [type: "t"])
        |> Zizq.Cron.put_entry(name: "b", expression: "0 2 * * *", job: [type: "t"])

      assert Enum.map(cron.entries, & &1.name) == ["a", "b"]

      # Upsert, not append: installing the same schedule twice leaves
      # one entry, so building it twice should too.
      updated = Zizq.Cron.put_entry(cron, name: "a", expression: "*/5 * * * *", job: [type: "t"])

      assert Enum.map(updated.entries, & &1.name) == ["a", "b"]
      assert Zizq.Cron.entry(updated, "a").expression == "*/5 * * * *"
    end

    test "delete_entry removes by name, and tolerates a miss" do
      cron =
        Zizq.Cron.new("my_app",
          entries: [[name: "a", expression: "* * * * *", job: [type: "t"]]]
        )

      assert Zizq.Cron.delete_entry(cron, "a").entries == []
      assert Zizq.Cron.delete_entry(cron, "absent") == cron
    end

    # Per entry, with no group-level default: the server has nowhere
    # to keep one, so a schedule read back would lose it and entries
    # added afterwards would quietly fall back to the server's own
    # timezone.
    test "each entry carries its own timezone" do
      name = server(200, group())

      Zizq.Cron.new("my_app",
        entries: [
          [name: "a", expression: "* * * * *", job: [type: "t"]],
          [name: "b", expression: "* * * * *", timezone: "UTC", job: [type: "t"]]
        ]
      )
      |> Zizq.replace_cron(name)

      assert_receive {:request, "PUT", _, body}
      [a, b] = body["entries"]

      refute Map.has_key?(a, "timezone")
      assert b["timezone"] == "UTC"
    end

    test "a group-level timezone is rejected rather than silently lost" do
      assert_raise ArgumentError, ~r/unknown cron options/, fn ->
        Zizq.Cron.new("my_app", timezone: "UTC", entries: [])
      end
    end

    # The loop the struct exists for: what comes back can go straight
    # back out.
    test "a schedule read from the server can be amended and replaced" do
      name = server(200, group())

      {:ok, cron} = Zizq.get_cron("my_app", name)
      assert_receive {:request, "GET", _, _}

      cron
      |> Zizq.Cron.delete_entry("digest")
      |> Zizq.Cron.put_entry(name: "nightly", expression: "0 3 * * *", job: [type: "t"])
      |> Zizq.replace_cron(name)

      assert_receive {:request, "PUT", "/crons/my_app", body}
      assert [%{"name" => "nightly"}] = body["entries"]
    end
  end

  describe "entry-level operations" do
    test "pause and resume patch one entry" do
      name = server(200, ~s({"name":"digest","expression":"* * * * *","paused":true}))

      assert {:ok, %Zizq.CronEntry{name: "digest", paused: true}} =
               Zizq.pause_cron_entry([cron: "my_app", entry: "digest"], name)

      assert_receive {:request, "PATCH", "/crons/my_app/entries/digest", %{"paused" => true}}

      Zizq.resume_cron_entry([cron: "my_app", entry: "digest"], name)
      assert_receive {:request, "PATCH", _, %{"paused" => false}}
    end

    test "delete removes one entry" do
      name = server(204, nil)

      assert Zizq.delete_cron_entry([cron: "my_app", entry: "digest"], name) == :ok
      assert_receive {:request, "DELETE", "/crons/my_app/entries/digest", _}
    end

    # Two bare strings would give no clue which is which.
    test "the group and entry must be named" do
      name = server(204, nil)

      assert_raise ArgumentError, ~r/:entry is required/, fn ->
        Zizq.delete_cron_entry([cron: "my_app"], name)
      end

      assert_raise ArgumentError, ~r/takes :cron and :entry/, fn ->
        Zizq.delete_cron_entry([group: "my_app", entry: "digest"], name)
      end
    end

    test "both names are escaped as single path segments" do
      name = server(204, nil)

      Zizq.delete_cron_entry([cron: "my app/v2", entry: "a/b"], name)

      assert_receive {:request, "DELETE", path, _}
      assert path == "/crons/my%20app%2Fv2/entries/a%2Fb"
    end
  end

  describe "delete and pause" do
    test "delete_cron removes a group" do
      name = server(204, nil)

      assert Zizq.delete_cron("my_app", name) == :ok
      assert_receive {:request, "DELETE", "/crons/my_app", _}
    end

    test "delete_all_crons reports how many went" do
      name = server(200, ~s({"deleted":3}))

      assert Zizq.delete_all_crons(name) == {:ok, 3}
      assert_receive {:request, "DELETE", "/crons", _}
    end

    test "pause and resume patch the group" do
      name = server(200, group(%{"paused" => true}))

      assert {:ok, %Zizq.Cron{paused: true}} = Zizq.pause_cron("my_app", name)
      assert_receive {:request, "PATCH", "/crons/my_app", %{"paused" => true}}

      Zizq.resume_cron("my_app", name)
      assert_receive {:request, "PATCH", "/crons/my_app", %{"paused" => false}}
    end

    # A cron name is one path segment, and the server permits names
    # holding characters that are not — a raw `/` would address a
    # different route.
    test "a name is escaped as a single path segment" do
      name = server(204, nil)

      Zizq.delete_cron("my app/v2", name)

      assert_receive {:request, "DELETE", path, _}
      assert path == "/crons/my%20app%2Fv2"
    end
  end
end
