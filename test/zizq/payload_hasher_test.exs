# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.PayloadHasherTest do
  @moduledoc """
  Payload hashing: which parts of a payload decide the key, what the
  path grammar accepts, and which changes must and must not move the
  digest.
  """

  use ExUnit.Case, async: true

  alias Zizq.PayloadHasher

  doctest Zizq.PayloadHasher

  defp digest(payload, opts \\ []) do
    opts
    |> Keyword.put_new(:prefix, false)
    |> PayloadHasher.new!()
    |> PayloadHasher.digest(payload)
  end

  describe "the whole payload" do
    test "the same payload hashes the same way twice" do
      payload = %{"user_id" => 42, "tags" => ["a", "b"]}

      assert digest(payload) == digest(payload)
    end

    # The reason for canonical JSON rather than hashing a serialised
    # form: map order is not part of the value.
    test "key order does not move the digest" do
      assert digest(%{"a" => 1, "b" => 2}) == digest(%{"b" => 2, "a" => 1})
    end

    test "array order does move the digest" do
      refute digest(%{"a" => [1, 2]}) == digest(%{"a" => [2, 1]})
    end

    # The framing markers exist for this: without them both would hash
    # the same byte stream.
    test "structure is not flattened away" do
      refute digest(%{"a" => [[1, 2], [12]]}) == digest(%{"a" => [[1], [2, 12]]})
      refute digest(%{"a" => [1, 2]}) == digest(%{"a" => [12]})
    end

    test "a missing key and an explicit null differ" do
      refute digest(%{"a" => 1}) == digest(%{"a" => 1, "b" => nil})
    end

    test "atom keys normalise to the strings the server would store" do
      assert digest(%{user_id: 42}) == digest(%{"user_id" => 42})
    end

    test "a non-map payload hashes fine" do
      assert is_binary(digest(42))
      assert is_binary(digest("hello"))
      assert is_binary(digest(nil))
      refute digest(42) == digest("42")
    end
  end

  describe ":only" do
    test "ignores everything outside the named paths" do
      a = digest(%{"user_id" => 1, "noise" => 1}, only: [".user_id"])
      b = digest(%{"user_id" => 1, "noise" => 999}, only: [".user_id"])

      assert a == b
    end

    test "still notices the named paths changing" do
      a = digest(%{"user_id" => 1}, only: [".user_id"])
      b = digest(%{"user_id" => 2}, only: [".user_id"])

      refute a == b
    end

    # Picked values keep their nesting, so a value at one path cannot
    # collide with the same value at another.
    test "preserves nesting, so paths cannot collide" do
      a = digest(%{"user" => %{"id" => 7}}, only: [".user.id"])
      b = digest(%{"id" => 7}, only: [".id"])

      refute a == b
    end

    test "several paths hash together" do
      a = digest(%{"a" => 1, "b" => 2, "c" => 3}, only: [".a", ".b"])
      b = digest(%{"a" => 1, "b" => 2, "c" => 999}, only: [".a", ".b"])
      c = digest(%{"a" => 1, "b" => 99}, only: [".a", ".b"])

      assert a == b
      refute a == c
    end

    test "order of the paths themselves does not matter" do
      payload = %{"a" => 1, "b" => 2}

      assert digest(payload, only: [".a", ".b"]) == digest(payload, only: [".b", ".a"])
    end

    # Otherwise a payload that omits an optional field would hash
    # differently from one that never carried it.
    test "a path matching nothing is skipped, not hashed as null" do
      assert digest(%{"a" => 1}, only: [".a", ".missing"]) == digest(%{"a" => 1}, only: [".a"])
    end

    test "every path missing still produces a digest" do
      assert is_binary(digest(%{"a" => 1}, only: [".nope"]))
      assert digest(%{"a" => 1}, only: [".nope"]) == digest(%{"b" => 2}, only: [".other"])
    end

    test "a single path need not be wrapped in a list" do
      payload = %{"a" => 1, "b" => 2}

      assert digest(payload, only: ".a") == digest(payload, only: [".a"])
    end

    test "`.` selects the whole payload" do
      payload = %{"a" => 1, "b" => 2}

      assert digest(payload, only: ["."]) == digest(payload)
    end

    test "array indexes select elements" do
      a = digest(%{"items" => [1, 2, 3]}, only: [".items[0]"])
      b = digest(%{"items" => [1, 999, 999]}, only: [".items[0]"])

      assert a == b
      refute a == digest(%{"items" => [9, 2, 3]}, only: [".items[0]"])
    end

    # The index has to survive, or two different positions would build
    # the same shape.
    test "different array indexes do not collide" do
      payload = %{"items" => [7, 7]}

      refute digest(payload, only: [".items[0]"]) == digest(payload, only: [".items[1]"])
    end

    test "a root array index" do
      assert digest([1, 2, 3], only: [".[0]"]) == digest([1, 999], only: [".[0]"])
    end
  end

  describe ":except" do
    test "ignores the named paths" do
      a = digest(%{"a" => 1, "at" => "t1"}, except: [".at"])
      b = digest(%{"a" => 1, "at" => "t2"}, except: [".at"])

      assert a == b
    end

    test "notices everything else" do
      a = digest(%{"a" => 1, "at" => "t"}, except: [".at"])
      b = digest(%{"a" => 2, "at" => "t"}, except: [".at"])

      refute a == b
    end

    test "removes a nested path without disturbing its siblings" do
      a = digest(%{"user" => %{"id" => 1, "seen" => "t1"}}, except: [".user.seen"])
      b = digest(%{"user" => %{"id" => 1, "seen" => "t2"}}, except: [".user.seen"])
      c = digest(%{"user" => %{"id" => 2, "seen" => "t1"}}, except: [".user.seen"])

      assert a == b
      refute a == c
    end

    test "a path matching nothing removes nothing" do
      assert digest(%{"a" => 1}, except: [".nope"]) == digest(%{"a" => 1})
    end

    test "`.` excludes everything, so every payload agrees" do
      assert digest(%{"a" => 1}, except: ["."]) == digest(%{"b" => 2}, except: ["."])
    end

    test "cannot be combined with :only" do
      assert_raise ArgumentError, ~r/cannot be combined/, fn ->
        PayloadHasher.new!(only: [".a"], except: [".b"])
      end
    end
  end

  describe "keys" do
    test "prefixed with the job type by default" do
      hasher = PayloadHasher.new!()

      assert "send_email:" <> digest = PayloadHasher.key(hasher, "send_email", %{"a" => 1})
      assert String.length(digest) == 64
    end

    # Two kinds of job with identical payloads are still different jobs.
    test "the prefix separates types carrying the same payload" do
      hasher = PayloadHasher.new!()
      payload = %{"a" => 1}

      refute PayloadHasher.key(hasher, "a", payload) == PayloadHasher.key(hasher, "b", payload)
    end

    test "the prefix can be turned off" do
      hasher = PayloadHasher.new!(prefix: false)
      payload = %{"a" => 1}

      assert PayloadHasher.key(hasher, "a", payload) == PayloadHasher.key(hasher, "b", payload)
    end
  end

  describe "path parsing" do
    test "accepts the documented forms" do
      assert PayloadHasher.parse_path!(".") == []
      assert PayloadHasher.parse_path!(".foo") == [key: "foo"]
      assert PayloadHasher.parse_path!(".foo.bar") == [key: "foo", key: "bar"]
      assert PayloadHasher.parse_path!(".foo[0]") == [key: "foo", index: 0]
      assert PayloadHasher.parse_path!(".[0]") == [index: 0]
      assert PayloadHasher.parse_path!(".a[0].b") == [key: "a", index: 0, key: "b"]
      assert PayloadHasher.parse_path!(".foo_bar1") == [key: "foo_bar1"]
    end

    test "a quoted key reaches names the bare grammar cannot" do
      assert PayloadHasher.parse_path!(~s(.["dotted.key"])) == [key: "dotted.key"]
      assert PayloadHasher.parse_path!(~s(.a.["b.c"])) == [key: "a", key: "b.c"]
      assert PayloadHasher.parse_path!(~s(.["with \\"quote\\""])) == [key: ~s(with "quote")]
    end

    test "a quoted key actually selects that key" do
      a = digest(%{"dotted.key" => 1, "noise" => 1}, only: [~s(.["dotted.key"])])
      b = digest(%{"dotted.key" => 1, "noise" => 2}, only: [~s(.["dotted.key"])])

      assert a == b
      refute a == digest(%{"dotted.key" => 9}, only: [~s(.["dotted.key"])])
    end

    test "rejects a path not starting with a dot" do
      assert_raise ArgumentError, ~r/must start with '\.'/, fn ->
        PayloadHasher.parse_path!("foo")
      end
    end

    test "rejects an unterminated quoted key" do
      assert_raise ArgumentError, ~r/unterminated quoted key/, fn ->
        PayloadHasher.parse_path!(~s(.["oops))
      end
    end

    test "rejects a malformed index" do
      assert_raise ArgumentError, ~r/invalid array index/, fn ->
        PayloadHasher.parse_path!(".a[x]")
      end

      assert_raise ArgumentError, ~r/invalid array index/, fn ->
        PayloadHasher.parse_path!(".a[0")
      end
    end

    test "rejects an unexpected character" do
      assert_raise ArgumentError, ~r/unexpected/, fn -> PayloadHasher.parse_path!(".a-b") end
    end

    test "rejects an empty path" do
      assert_raise ArgumentError, ~r/must start with '\.'/, fn ->
        PayloadHasher.parse_path!("")
      end
    end
  end

  # Pinned so the digest cannot drift silently: a change here breaks
  # every unique key already in flight on a running server.
  describe "digest stability" do
    test "known payloads hash to known digests" do
      assert digest(%{"user_id" => 42, "template" => "welcome"}) ==
               "1f98104cc5a072ae84731379f5888c48c1886f7d58681e806cc9cca4d601f765"

      assert digest(%{"a" => nil, "b" => [1, nil]}) ==
               "2d182bba594ddfd1512982de06a9dbc2f18286888b9e0ab9535fefffedc6a31d"

      assert digest(%{"s" => "héllo ✨"}) ==
               "cb040b4872cfd3ac08cfd019b16f7b07a12bd0f15ced13cf421fef35a4ed459a"
    end

    # Every digest above is byte-identical to the Node client's for the
    # same payload. Integral floats are the one exception: JSON has no
    # int/float distinction, so JavaScript normalises 1.0 to 1 where
    # Elixir keeps it a float and encodes "1.0". Uniqueness is a
    # within-producer guarantee, so this is recorded rather than fixed.
    test "an integral float does not hash as its integer" do
      refute digest(%{"n" => 1.0}) == digest(%{"n" => 1})

      assert digest(%{"n" => 1}) ==
               "8b50cec96a652e1772c4f3e2111029eda44fd4bbe94e831da9894fa1e0841682"
    end
  end
end
