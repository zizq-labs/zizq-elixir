# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.BatchConfigTest do
  @moduledoc """
  Batch configuration, mostly the expressions generated from a path and
  a cap so that callers never write jq.

  The generated forms are pinned literally: they are a contract with
  the server's jq evaluator and with the other clients, which template
  the identical strings.
  """

  use ExUnit.Case, async: true

  alias Zizq.BatchConfig

  describe "generated from :limit and :path" do
    test "the predicate caps the combined length at the path" do
      assert BatchConfig.new!(limit: 100, path: ".deviceIds").when ==
               "(($existing | .deviceIds) + ($new | .deviceIds)) | length <= 100"
    end

    test "the fold appends the incoming value onto the batch" do
      assert BatchConfig.new!(limit: 100, path: ".deviceIds").fold ==
               "$existing | .deviceIds += ($new | .deviceIds)"
    end

    # Pipe access rather than `$existing.path` exists for this case:
    # `$existing.` is a jq syntax error, so one template could not
    # otherwise cover both the root and a nested path.
    test "the root path batches the whole payload" do
      config = BatchConfig.new!(limit: 1_000)

      assert config.when == "(($existing | .) + ($new | .)) | length <= 1000"
      assert config.fold == "$existing | . += ($new | .)"
    end

    test ":path defaults to the root" do
      assert BatchConfig.new!(limit: 5) == BatchConfig.new!(limit: 5, path: ".")
    end

    test ":dedup folds through unique" do
      assert BatchConfig.new!(limit: 100, path: ".ids", dedup: true).fold ==
               "$existing | .ids = ((.ids) + ($new | .ids) | unique)"
    end

    test ":sorted folds through sort" do
      assert BatchConfig.new!(limit: 100, path: ".ids", sorted: true).fold ==
               "$existing | .ids = ((.ids) + ($new | .ids) | sort)"
    end

    # `unique` sorts as well, so there is nothing `:sorted` could add.
    test ":dedup subsumes :sorted" do
      both = BatchConfig.new!(limit: 100, path: ".ids", dedup: true, sorted: true)

      assert both.fold == BatchConfig.new!(limit: 100, path: ".ids", dedup: true).fold
    end

    test "neither flag leaves the plain append fold" do
      assert BatchConfig.new!(limit: 100, path: ".ids", dedup: false, sorted: false).fold ==
               "$existing | .ids += ($new | .ids)"
    end
  end

  describe "the derived key" do
    # What makes the common case need no key at all: two enqueues alike
    # in every respect but what they contribute belong together.
    test "hashes everything except the batch path" do
      config = BatchConfig.new!(limit: 100, path: ".device_ids")

      assert %Zizq.PayloadHasher{except: [[key: "device_ids"]]} = config.key
    end

    test "so payloads differing only at the batch path share a batch" do
      config = BatchConfig.new!(limit: 100, path: ".device_ids")

      a = BatchConfig.to_wire(config, "push", %{"platform" => "apple", "device_ids" => ["a"]})

      b =
        BatchConfig.to_wire(config, "push", %{"platform" => "apple", "device_ids" => ["b", "c"]})

      c = BatchConfig.to_wire(config, "push", %{"platform" => "google", "device_ids" => ["a"]})

      assert a["key"] == b["key"]
      refute a["key"] == c["key"]
    end

    # Nothing is left to tell two whole-payload batches apart, so every
    # job of a type shares one batch.
    test "a root path leaves one batch per job type" do
      config = BatchConfig.new!(limit: 1_000)

      a = BatchConfig.to_wire(config, "audit", [%{"a" => 1}])
      b = BatchConfig.to_wire(config, "audit", [%{"b" => 2}])

      assert a["key"] == b["key"]
      refute a["key"] == BatchConfig.to_wire(config, "other", [%{"a" => 1}])["key"]
    end

    test "can be overridden with a string" do
      config = BatchConfig.new!(limit: 100, path: ".ids", key: "push:apple")

      assert BatchConfig.to_wire(config, "push", %{"ids" => []})["key"] == "push:apple"
    end

    test "can be overridden with a different hasher" do
      config =
        BatchConfig.new!(
          limit: 100,
          path: ".ids",
          key: {:payload, only: [".tenant_id"]}
        )

      a = BatchConfig.to_wire(config, "push", %{"tenant_id" => 1, "ids" => ["x"], "noise" => 1})
      b = BatchConfig.to_wire(config, "push", %{"tenant_id" => 1, "ids" => ["y"], "noise" => 2})

      assert a["key"] == b["key"]
    end
  end

  describe "writing the expressions by hand" do
    test "key, when and fold are taken verbatim" do
      config =
        BatchConfig.new!(
          key: "digest:42",
          when: "$existing.count < 100",
          fold: "$existing | .count += 1"
        )

      wire = BatchConfig.to_wire(config, "t", %{})

      assert wire == %{
               "key" => "digest:42",
               "when" => "$existing.count < 100",
               "fold" => "$existing | .count += 1"
             }
    end

    test "all three are required" do
      for partial <- [[key: "k"], [key: "k", when: "true"], [when: "true", fold: "$new"]] do
        assert_raise ArgumentError, ~r/batch :\w+ is required/, fn ->
          BatchConfig.new!(partial)
        end
      end
    end

    # They would be generating the same two fields, so one of them
    # would silently win.
    test "cannot be mixed with :limit" do
      for clashing <- [[when: "true"], [fold: "$new"]] do
        assert_raise ArgumentError, ~r/is generated from :limit and :path/, fn ->
          BatchConfig.new!([limit: 10, path: ".ids"] ++ clashing)
        end
      end
    end
  end

  describe "validation" do
    test "rejects a non-positive limit" do
      for bad <- [0, -1, "10", 1.5] do
        assert_raise ArgumentError, ~r/:limit must be a positive integer/, fn ->
          BatchConfig.new!(limit: bad, path: ".ids")
        end
      end
    end

    # Otherwise the typo reaches the server as jq that quietly matches
    # nothing, and the batch never folds.
    test "rejects a malformed path" do
      assert_raise ArgumentError, ~r/must start with '\./, fn ->
        BatchConfig.new!(limit: 10, path: "ids")
      end
    end

    test "rejects a non-string path" do
      assert_raise ArgumentError, ~r/:path must be a string/, fn ->
        BatchConfig.new!(limit: 10, path: :ids)
      end
    end

    test "rejects unknown keys" do
      assert_raise ArgumentError, ~r/unknown batch keys/, fn ->
        BatchConfig.new!(limit: 10, within: 5)
      end
    end

    test "is idempotent over an existing struct" do
      config = BatchConfig.new!(limit: 10, path: ".ids")

      assert BatchConfig.new!(config) == config
    end
  end
end
