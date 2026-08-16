# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule ZizqTest do
  use ExUnit.Case, async: true

  doctest Zizq

  describe "version/0" do
    test "is a well-formed version string" do
      assert {:ok, %Version{}} = Version.parse(Zizq.version())
    end
  end
end
