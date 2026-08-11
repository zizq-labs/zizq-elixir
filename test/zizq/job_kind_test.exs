# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.JobKindTest do
  @moduledoc """
  The `use Zizq.JobKind` macro: what it generates, what it rejects, and
  which `perform` it wires up.
  """

  use ExUnit.Case, async: true

  defmodule Minimal do
    use Zizq.JobKind, type: "minimal"

    @impl Zizq.JobKind
    def perform(payload), do: {:one, payload}
  end

  defmodule Configured do
    use Zizq.JobKind,
      type: "configured",
      queue: "emails",
      priority: 100,
      retry_limit: 5,
      backoff: [base: :timer.seconds(15), exponent: 4.0, jitter: :timer.seconds(30)],
      retention: [completed: :timer.hours(24)]

    @impl Zizq.JobKind
    def perform(payload, job), do: {:two, payload, job}
  end

  defmodule Both do
    use Zizq.JobKind, type: "both"

    @impl Zizq.JobKind
    def perform(payload), do: {:one, payload}

    @impl Zizq.JobKind
    def perform(payload, _job), do: {:two, payload}
  end

  # Each compiled module needs its own name, or redefining one would
  # warn and the failure under test would be lost in the noise.
  defp compile!(body) do
    name = "Compiled#{System.unique_integer([:positive])}"
    Code.compile_string("defmodule #{name} do\n#{body}\nend")
  end

  describe "type/0" do
    test "returns the type given to `use`" do
      assert Minimal.type() == "minimal"
      assert Configured.type() == "configured"
    end
  end

  describe "new/2" do
    test "carries the type and payload" do
      assert %Zizq.Enqueue{type: "minimal", payload: %{"user_id" => 42}} =
               Minimal.new(%{"user_id" => 42})
    end

    test "leaves unset options unset, so the server's defaults apply" do
      enqueue = Minimal.new(%{})

      assert enqueue.queue == "default"
      assert enqueue.priority == nil
      assert enqueue.retry_limit == nil
      assert enqueue.backoff == nil
      assert enqueue.retention == nil
    end

    test "applies the module's defaults" do
      enqueue = Configured.new(%{})

      assert enqueue.queue == "emails"
      assert enqueue.priority == 100
      assert enqueue.retry_limit == 5
      assert %Zizq.Backoff{base: 15_000, exponent: 4.0, jitter: 30_000} = enqueue.backoff
      assert %Zizq.Retention{completed: 86_400_000} = enqueue.retention
    end

    test "overrides win over the module's defaults, per enqueue" do
      enqueue = Configured.new(%{}, priority: 10, queue: "urgent")

      assert enqueue.priority == 10
      assert enqueue.queue == "urgent"
      # Untouched by the override.
      assert enqueue.retry_limit == 5
    end

    test "an override leaves later enqueues alone" do
      _ = Configured.new(%{}, priority: 10)

      assert Configured.new(%{}).priority == 100
    end

    test "rejects an unknown override rather than dropping it" do
      assert_raise ArgumentError, ~r/unknown enqueue key/, fn ->
        Configured.new(%{}, prioriti: 10)
      end
    end

    # Overriding it would send the job to a different handler than the
    # module it was built from.
    test "rejects an attempt to override the type" do
      assert_raise ArgumentError, ~r/type is fixed by the module/, fn ->
        Minimal.new(%{}, type: "something_else")
      end
    end
  end

  describe "options are validated when the module compiles" do
    test "a malformed backoff fails the build, not the first enqueue" do
      assert_raise ArgumentError, fn ->
        compile!(
          ~s|use Zizq.JobKind, type: "x", backoff: [base: "soon"]\ndef perform(_), do: :ok|
        )
      end
    end

    test "an unknown option is rejected" do
      assert_raise ArgumentError, ~r/unknown enqueue key/, fn ->
        compile!(~s|use Zizq.JobKind, type: "x", queeue: "typo"\ndef perform(_), do: :ok|)
      end
    end

    test "`:type` is required" do
      assert_raise ArgumentError, ~r/non-empty string `:type`/, fn ->
        compile!("use Zizq.JobKind, queue: \"emails\"\ndef perform(_), do: :ok")
      end
    end

    test "`:type` must not be empty" do
      assert_raise ArgumentError, ~r/non-empty string `:type`/, fn ->
        compile!(~s|use Zizq.JobKind, type: ""\ndef perform(_), do: :ok|)
      end
    end

    # A payload belongs to one enqueue, not to every job of this kind.
    test "`:payload` is rejected by name, not left to the unknown-key error" do
      assert_raise ArgumentError, ~r/belongs to a single enqueue/, fn ->
        compile!(~s|use Zizq.JobKind, type: "x", payload: %{}\ndef perform(_), do: :ok|)
      end
    end
  end

  describe "unique keys from the payload" do
    defmodule Unique do
      use Zizq.JobKind,
        type: "unique",
        unique_key: {:payload, only: [".user_id", ".template"]},
        unique_while: :queued

      @impl Zizq.JobKind
      def perform(_payload), do: :ok
    end

    defp wire(enqueue), do: Zizq.Enqueue.to_wire(enqueue)

    # Held as a parsed hasher rather than a string, because the key
    # depends on the payload of each individual enqueue.
    test "the paths are parsed when the module compiles" do
      assert %Zizq.PayloadHasher{only: [[key: "user_id"], [key: "template"]]} =
               Unique.new(%{}).unique_key
    end

    test "the key is derived from the payload at enqueue time" do
      key = wire(Unique.new(%{"user_id" => 42, "template" => "welcome"}))["unique_key"]

      assert "unique:" <> digest = key
      assert String.length(digest) == 64
    end

    test "payload fields outside the paths do not change the key" do
      a = wire(Unique.new(%{"user_id" => 42, "template" => "w", "at" => "t1"}))
      b = wire(Unique.new(%{"user_id" => 42, "template" => "w", "at" => "t2"}))

      assert a["unique_key"] == b["unique_key"]
    end

    test "a named field changing does change the key" do
      a = wire(Unique.new(%{"user_id" => 42, "template" => "w"}))
      b = wire(Unique.new(%{"user_id" => 43, "template" => "w"}))

      refute a["unique_key"] == b["unique_key"]
    end

    test "unique_while rides along" do
      assert wire(Unique.new(%{"user_id" => 1}))["unique_while"] == "queued"
    end

    test "a plain string key still passes straight through" do
      defmodule StaticKey do
        use Zizq.JobKind, type: "static", unique_key: "fixed"

        @impl Zizq.JobKind
        def perform(_), do: :ok
      end

      assert wire(StaticKey.new(%{"a" => 1}))["unique_key"] == "fixed"
    end

    test "`:payload` alone hashes the whole payload" do
      defmodule WholePayload do
        use Zizq.JobKind, type: "whole", unique_key: :payload

        @impl Zizq.JobKind
        def perform(_), do: :ok
      end

      a = wire(WholePayload.new(%{"a" => 1}))
      b = wire(WholePayload.new(%{"a" => 2}))

      assert "whole:" <> _ = a["unique_key"]
      refute a["unique_key"] == b["unique_key"]
    end

    # It would otherwise be a runtime failure on the first enqueue,
    # long after the typo was written.
    test "a malformed path fails the build" do
      assert_raise ArgumentError, ~r/must start with '\.'/, fn ->
        compile!(~s|use Zizq.JobKind, type: "x", unique_key: {:payload, only: ["user_id"]}
        def perform(_), do: :ok|)
      end
    end

    test "an override can replace the derived key for one enqueue" do
      assert wire(Unique.new(%{"user_id" => 1}, unique_key: "manual"))["unique_key"] == "manual"
    end
  end

  describe "batching declared on a job module" do
    defmodule Digest do
      use Zizq.JobKind,
        type: "digest",
        batch: [limit: 100, path: ".events"]

      @impl Zizq.JobKind
      def perform(_payload), do: :ok
    end

    defmodule Audit do
      use Zizq.JobKind, type: "audit", batch: [limit: 1_000]

      @impl Zizq.JobKind
      def perform(_payload), do: :ok
    end

    test "the expressions are generated, so the module declares neither" do
      wire = Zizq.Enqueue.to_wire(Digest.new(%{"tenant_id" => 1, "events" => []}))

      assert wire["batch"]["when"] ==
               "(($existing | .events) + ($new | .events)) | length <= 100"

      assert wire["batch"]["fold"] == "$existing | .events += ($new | .events)"
    end

    test "the key hashes everything but the batch, and is parsed at compile time" do
      assert %Zizq.PayloadHasher{except: [[key: "events"]]} = Digest.new(%{}).batch.key
    end

    # What an enqueue contributes is exactly what should not split the
    # batch; everything else about it should.
    test "each enqueue derives its key from its own payload" do
      a = Zizq.Enqueue.to_wire(Digest.new(%{"tenant_id" => 1, "events" => [1]}))
      b = Zizq.Enqueue.to_wire(Digest.new(%{"tenant_id" => 1, "events" => [2, 3]}))
      c = Zizq.Enqueue.to_wire(Digest.new(%{"tenant_id" => 2, "events" => [1]}))

      assert a["batch"]["key"] == b["batch"]["key"]
      refute a["batch"]["key"] == c["batch"]["key"]
      assert "digest:" <> _ = a["batch"]["key"]
    end

    test "an omitted path batches the whole payload" do
      wire = Zizq.Enqueue.to_wire(Audit.new([%{"a" => 1}]))

      assert wire["batch"]["when"] == "(($existing | .) + ($new | .)) | length <= 1000"
      assert wire["batch"]["fold"] == "$existing | . += ($new | .)"
    end

    # Nothing is left to distinguish them once the whole payload is the
    # batch, so every job of the type shares one.
    test "a whole-payload batch is one batch per job type" do
      a = Zizq.Enqueue.to_wire(Audit.new([%{"a" => 1}]))
      b = Zizq.Enqueue.to_wire(Audit.new([%{"b" => 2}]))

      assert a["batch"]["key"] == b["batch"]["key"]
      assert "audit:" <> _ = a["batch"]["key"]
    end

    test "the fold mode carries through from the module" do
      defmodule Deduped do
        use Zizq.JobKind, type: "deduped", batch: [limit: 10, path: ".ids", dedup: true]

        @impl Zizq.JobKind
        def perform(_), do: :ok
      end

      wire = Zizq.Enqueue.to_wire(Deduped.new(%{"ids" => []}))

      assert wire["batch"]["fold"] == "$existing | .ids = ((.ids) + ($new | .ids) | unique)"
    end

    test "the expressions can still be written by hand" do
      defmodule Counted do
        use Zizq.JobKind,
          type: "counted",
          batch: [key: "k", when: "$existing.count < 10", fold: "$existing | .count += 1"]

        @impl Zizq.JobKind
        def perform(_), do: :ok
      end

      wire = Zizq.Enqueue.to_wire(Counted.new(%{}))

      assert wire["batch"]["when"] == "$existing.count < 10"
      assert wire["batch"]["key"] == "k"
    end

    test "a malformed path fails the build" do
      assert_raise ArgumentError, ~r/must start with '\.'/, fn ->
        compile!(~s|use Zizq.JobKind, type: "x", batch: [limit: 10, path: "events"]
        def perform(_), do: :ok|)
      end
    end

    # The server refuses the combination, and a job module declaring
    # both would fail on every enqueue rather than once at build time.
    test "a module cannot declare both a batch and a unique key" do
      assert_raise ArgumentError, ~r/:unique_key and :batch cannot be combined/, fn ->
        compile!(
          ~s|use Zizq.JobKind, type: "x", unique_key: :payload, batch: [key: "k", when: "true", fold: "$new"]
        def perform(_), do: :ok|
        )
      end
    end
  end

  describe "perform resolution" do
    test "dispatches to perform/1 when only it is defined" do
      assert Minimal.__zizq_perform__(%{"a" => 1}, %Zizq.Job{id: "j"}) == {:one, %{"a" => 1}}
    end

    test "dispatches to perform/2 when only it is defined" do
      job = %Zizq.Job{id: "j"}
      assert Configured.__zizq_perform__(%{"a" => 1}, job) == {:two, %{"a" => 1}, job}
    end

    # Defining a /1 convenience wrapper alongside /2 is ordinary
    # Elixir, so it resolves rather than failing.
    test "prefers perform/2 when both are defined" do
      assert Both.__zizq_perform__(%{"a" => 1}, %Zizq.Job{id: "j"}) == {:two, %{"a" => 1}}
    end

    test "defining neither fails at compile time" do
      error =
        assert_raise CompileError, fn ->
          compile!(~s|use Zizq.JobKind, type: "forgetful"|)
        end

      assert Exception.message(error) =~ "defines neither perform/1 nor perform/2"
    end
  end
end
