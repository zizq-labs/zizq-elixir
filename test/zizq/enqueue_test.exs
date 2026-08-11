# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.EnqueueTest do
  use ExUnit.Case, async: true

  alias Zizq.Enqueue

  describe "new!/1 defaults" do
    test "only :type is required" do
      enqueue = Enqueue.new!(type: "send_email")

      assert enqueue.type == "send_email"
      assert enqueue.queue == "default"
      assert enqueue.payload == %{}
    end

    test "accepts a map as well as a keyword list" do
      assert Enqueue.new!(%{type: "a"}) == Enqueue.new!(type: "a")
    end

    test "is idempotent over an existing struct" do
      enqueue = Enqueue.new!(type: "a")
      assert Enqueue.new!(enqueue) == enqueue
    end
  end

  describe "new!/1 validation" do
    # Without this a typo silently enqueues a job with an empty payload
    # that fails later, somewhere else.
    test "rejects unknown keys rather than ignoring them" do
      error =
        assert_raise ArgumentError, fn ->
          Enqueue.new!(type: "a", payloads: %{"x" => 1})
        end

      assert Exception.message(error) =~ "unknown enqueue key: [:payloads]"
      assert Exception.message(error) =~ "Known keys are"
    end

    test "requires a non-empty type" do
      for bad <- [nil, "", :send_email, 42] do
        assert_raise ArgumentError, ~r/:type is required/, fn ->
          Enqueue.new!(type: bad)
        end
      end
    end

    test "requires a non-empty queue" do
      assert_raise ArgumentError, ~r/:queue must be/, fn ->
        Enqueue.new!(type: "a", queue: "")
      end
    end

    test "rejects an unknown uniqueness scope" do
      assert_raise ArgumentError, ~r/:unique_while must be one of/, fn ->
        Enqueue.new!(type: "a", unique_key: "k", unique_while: :forever)
      end
    end

    # The server rejects this on both endpoints; catching it locally
    # turns a round trip into an immediate error at the call site.
    test "rejects unique_key combined with batch" do
      assert_raise ArgumentError, ~r/:unique_key and :batch cannot be combined/, fn ->
        Enqueue.new!(
          type: "a",
          unique_key: "k",
          batch: [key: "b", when: "true", fold: "$new"]
        )
      end
    end

    # Silently ignoring it would look like uniqueness was configured.
    test "rejects a uniqueness scope with no key" do
      assert_raise ArgumentError, ~r/no effect without :unique_key/, fn ->
        Enqueue.new!(type: "a", unique_while: :queued)
      end
    end
  end

  describe "to_wire/1" do
    test "sends only type, queue and payload by default" do
      wire = Enqueue.new!(type: "send_email") |> Enqueue.to_wire()

      # Everything else is omitted so the server's own defaults apply
      # and keep tracking its configuration.
      assert wire == %{"type" => "send_email", "queue" => "default", "payload" => %{}}
    end

    test "includes optional fields when set" do
      wire =
        Enqueue.new!(
          type: "send_email",
          queue: "emails",
          payload: %{"user_id" => 42},
          priority: 100,
          retry_limit: 5
        )
        |> Enqueue.to_wire()

      assert wire["queue"] == "emails"
      assert wire["payload"] == %{"user_id" => 42}
      assert wire["priority"] == 100
      assert wire["retry_limit"] == 5
    end

    test "converts a DateTime ready_at to Unix milliseconds" do
      at = ~U[2026-08-08 09:00:00.000Z]
      wire = Enqueue.new!(type: "a", ready_at: at) |> Enqueue.to_wire()

      assert wire["ready_at"] == DateTime.to_unix(at, :millisecond)
      assert is_integer(wire["ready_at"])
    end

    test "passes integer ready_at through untouched" do
      wire = Enqueue.new!(type: "a", ready_at: 1_786_172_985_237) |> Enqueue.to_wire()
      assert wire["ready_at"] == 1_786_172_985_237
    end

    test "renames duration fields to the wire's _ms suffix" do
      wire =
        Enqueue.new!(
          type: "a",
          backoff: [base: :timer.seconds(15), exponent: 4, jitter: :timer.seconds(30)],
          retention: [completed: :timer.hours(24)]
        )
        |> Enqueue.to_wire()

      assert wire["backoff"] == %{"base_ms" => 15_000, "exponent" => 4.0, "jitter_ms" => 30_000}
      # `dead` was not set, so it is absent rather than null.
      assert wire["retention"] == %{"completed_ms" => 86_400_000}
    end

    # JSON null is a valid payload and the server requires the field on
    # every enqueue, so an explicit nil must be sent rather than
    # compacted away with the optional fields.
    test "sends an explicit nil payload rather than omitting it" do
      wire = Enqueue.new!(type: "a", payload: nil) |> Enqueue.to_wire()

      assert Map.has_key?(wire, "payload")
      assert wire["payload"] == nil
    end

    test "sends the uniqueness scope as a string" do
      wire =
        Enqueue.new!(type: "a", unique_key: "k", unique_while: :active) |> Enqueue.to_wire()

      assert wire["unique_key"] == "k"
      assert wire["unique_while"] == "active"
    end
  end

  # A job module is the convenient way to derive a unique key, but not
  # the only one: an enqueue built by hand takes the same shorthand,
  # parsing its paths when the enqueue is built rather than when the
  # module compiles.
  describe "unique keys derived from the payload" do
    defp key(input), do: input |> Enqueue.new!() |> Enqueue.to_wire() |> Map.get("unique_key")

    test "`{:payload, only: paths}` narrows the key to those paths" do
      a =
        key(type: "t", payload: %{"id" => 1, "at" => "t1"}, unique_key: {:payload, only: [".id"]})

      b =
        key(type: "t", payload: %{"id" => 1, "at" => "t2"}, unique_key: {:payload, only: [".id"]})

      c =
        key(type: "t", payload: %{"id" => 2, "at" => "t1"}, unique_key: {:payload, only: [".id"]})

      assert a == b
      refute a == c
      assert "t:" <> _ = a
    end

    test "`{:payload, except: paths}` ignores those paths" do
      a =
        key(
          type: "t",
          payload: %{"id" => 1, "at" => "t1"},
          unique_key: {:payload, except: [".at"]}
        )

      b =
        key(
          type: "t",
          payload: %{"id" => 1, "at" => "t2"},
          unique_key: {:payload, except: [".at"]}
        )

      assert a == b
    end

    test "`:payload` hashes the whole payload" do
      a = key(type: "t", payload: %{"id" => 1}, unique_key: :payload)
      b = key(type: "t", payload: %{"id" => 2}, unique_key: :payload)

      assert "t:" <> _ = a
      refute a == b
    end

    test "a hasher can be passed directly" do
      hasher = Zizq.PayloadHasher.new!(only: [".id"])

      assert key(type: "t", payload: %{"id" => 1, "at" => "x"}, unique_key: hasher) ==
               key(type: "t", payload: %{"id" => 1}, unique_key: {:payload, only: [".id"]})
    end

    test "a map of attributes takes the shorthand too" do
      assert "t:" <> _ = key(%{type: "t", payload: %{"id" => 1}, unique_key: :payload})
    end

    # Set on a struct by hand rather than passed as attributes; the
    # shorthand belongs to the option, not to one way of building one.
    test "a struct built by hand takes the shorthand" do
      enqueue = %Enqueue{type: "t", payload: %{"id" => 1}, unique_key: {:payload, only: [".id"]}}

      assert key(enqueue) ==
               key(type: "t", payload: %{"id" => 1}, unique_key: {:payload, only: [".id"]})
    end

    test "the key follows the payload, not the enqueue it was declared on" do
      hasher = Zizq.PayloadHasher.new!(only: [".id"])

      refute key(type: "t", payload: %{"id" => 1}, unique_key: hasher) ==
               key(type: "t", payload: %{"id" => 2}, unique_key: hasher)
    end

    test "the type takes part, so two kinds with one payload differ" do
      refute key(type: "a", payload: %{"id" => 1}, unique_key: :payload) ==
               key(type: "b", payload: %{"id" => 1}, unique_key: :payload)
    end

    test "unique_while rides along with a derived key" do
      wire =
        Enqueue.new!(
          type: "t",
          payload: %{"id" => 1},
          unique_key: :payload,
          unique_while: :active
        )
        |> Enqueue.to_wire()

      assert "t:" <> _ = wire["unique_key"]
      assert wire["unique_while"] == "active"
    end

    test "a malformed path is rejected when the enqueue is built" do
      assert_raise ArgumentError, ~r/must start with '\.'/, fn ->
        Enqueue.new!(type: "t", payload: %{}, unique_key: {:payload, only: ["id"]})
      end
    end

    test "a derived key still cannot be combined with a batch" do
      assert_raise ArgumentError, ~r/:unique_key and :batch cannot be combined/, fn ->
        Enqueue.new!(
          type: "t",
          payload: %{},
          unique_key: :payload,
          batch: [key: "b", when: "true", fold: "$new"]
        )
      end
    end

    test "an unusable value is rejected" do
      assert_raise ArgumentError, ~r/must be a string or a Zizq.PayloadHasher/, fn ->
        Enqueue.new!(type: "t", payload: %{}, unique_key: 42)
      end
    end
  end

  describe "batch" do
    test "is omitted unless configured" do
      refute Map.has_key?(Enqueue.new!(type: "a") |> Enqueue.to_wire(), "batch")
    end

    test "is sent verbatim, jq expressions included" do
      wire =
        Enqueue.new!(
          type: "a",
          batch: [key: "digest:42", when: "$existing.count < 100", fold: "$existing"]
        )
        |> Enqueue.to_wire()

      assert wire["batch"] == %{
               "key" => "digest:42",
               "when" => "$existing.count < 100",
               "fold" => "$existing"
             }
    end

    test "requires all three fields" do
      for partial <- [[key: "k"], [key: "k", when: "true"], [when: "true", fold: "$new"]] do
        assert_raise ArgumentError, ~r/batch :\w+ is required/, fn ->
          Enqueue.new!(type: "a", batch: partial)
        end
      end
    end
  end

  describe "backoff validation" do
    test "requires all three parameters together" do
      for partial <- [[base: 1], [base: 1, jitter: 2], [exponent: 2.0]] do
        assert_raise ArgumentError, ~r/invalid backoff/, fn ->
          Enqueue.new!(type: "a", backoff: partial)
        end
      end
    end

    test "accepts an integer exponent and normalises it to a float" do
      assert Zizq.Backoff.new!(base: 1, exponent: 4, jitter: 2).exponent === 4.0
    end

    test "rejects a float where milliseconds are expected" do
      assert_raise ArgumentError, ~r/milliseconds/, fn ->
        Zizq.Backoff.new!(base: 1.5, exponent: 4, jitter: 2)
      end
    end
  end
end
