# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule ZizqTest do
  use ExUnit.Case, async: true

  doctest Zizq

  describe "version/0" do
    test "is a well-formed version string" do
      assert {:ok, %Version{}} = Version.parse(Zizq.version())
    end

    test "is a pre-release until the client is feature-complete" do
      # Guards the release convention: development builds ship as
      # `0.6.0-alpha.N` so an ordinary `~> 0.6.0` requirement cannot
      # resolve them. Delete this once 0.6.0 proper is cut.
      assert {:ok, version} = Version.parse(Zizq.version())
      refute version.pre == [], "expected a pre-release version, got #{Zizq.version()}"
      refute Version.match?(Zizq.version(), "~> 0.6.0")
    end
  end
end
