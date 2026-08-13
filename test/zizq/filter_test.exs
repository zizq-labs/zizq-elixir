# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.FilterTest do
  @moduledoc """
  Encoding filters into the query parameters the server reads.

  The encodings are pinned literally: comma-delimited sets and
  `A..B` ranges are a wire contract, and a plausible-looking variant
  would be silently ignored or read as something else.
  """

  use ExUnit.Case, async: true

  alias Zizq.Filter

  defp params(filters), do: filters |> Filter.to_params() |> Enum.sort()

  describe "sets" do
    test "a single value goes out bare" do
      assert params(queue: "emails") == [queue: "emails"]
    end

    test "a list is comma-delimited" do
      assert params(queue: ["emails", "webhooks"]) == [queue: "emails,webhooks"]
    end

    test "atoms become strings, which is how statuses are written" do
      assert params(status: [:ready, :in_flight]) == [status: "ready,in_flight"]
      assert params(status: :ready) == [status: "ready"]
    end

    test "ids and types encode the same way" do
      assert params(id: ["a", "b"], type: "send_email") == [id: "a,b", type: "send_email"]
    end

    # The separator is the wire format, so a value containing one would
    # silently become two filters.
    test "a value containing a comma is rejected" do
      assert_raise ArgumentError, ~r/cannot contain a comma/, fn ->
        params(queue: "a,b")
      end
    end

    test "an empty list narrows nothing rather than matching nothing" do
      assert params(queue: []) == []
    end

    test "a nil filter is left out entirely" do
      assert params(queue: nil, status: :ready) == [status: "ready"]
    end
  end

  describe "ranges" do
    test "a bare number matches exactly" do
      assert params(priority: 5) == [priority: "5"]
    end

    test "a Range becomes an inclusive span" do
      assert params(priority: 1..10) == [priority: "1..10"]
    end

    # Elixir has no open-ended Range, so the keyword form covers what
    # `5..` and `..5` express in Ruby.
    test "one-sided bounds leave the other end empty" do
      assert params(priority: [min: 5]) == [priority: "5.."]
      assert params(priority: [max: 5]) == [priority: "..5"]
      assert params(priority: [min: 1, max: 10]) == [priority: "1..10"]
    end

    test "attempts and ready_at take the same shapes" do
      assert params(attempts: 0) == [attempts: "0"]
      assert params(attempts: 1..3) == [attempts: "1..3"]
      assert params(ready_at: [min: 1_000, max: 2_000]) == [ready_at: "1000..2000"]
    end

    test "ready_at accepts DateTimes, converted to milliseconds" do
      at = ~U[2026-08-13 09:00:00Z]
      ms = DateTime.to_unix(at, :millisecond)

      assert params(ready_at: at) == [ready_at: Integer.to_string(ms)]
      assert params(ready_at: [min: at]) == [ready_at: "#{ms}.."]
    end

    # A stepped range describes a sequence; the server matches a span,
    # so honouring only the endpoints would quietly match more than was
    # asked for.
    test "a stepped range is rejected rather than flattened" do
      assert_raise ArgumentError, ~r/stepped range/, fn ->
        params(priority: 1..10//2)
      end
    end

    test "empty bounds are rejected" do
      assert_raise ArgumentError, ~r/at least one of :min and :max/, fn ->
        params(priority: [])
      end
    end

    test "an unknown bound is rejected" do
      assert_raise ArgumentError, ~r/takes :min and :max/, fn ->
        params(priority: [from: 1])
      end
    end

    test "a non-numeric bound is rejected" do
      assert_raise ArgumentError, ~r/bounds must be integers/, fn ->
        params(priority: [min: "5"])
      end
    end
  end

  describe "jq filter" do
    test "goes out verbatim" do
      assert params(filter: ".user_id == 42") == [filter: ".user_id == 42"]
    end

    test "must be a string" do
      assert_raise ArgumentError, ~r/must be a jq expression/, fn ->
        params(filter: [".user_id"])
      end
    end
  end

  describe "validation" do
    test "an unknown filter is rejected rather than ignored" do
      assert_raise ArgumentError, ~r/unknown filter/, fn ->
        params(queeue: "emails")
      end
    end

    test "no filters narrow nothing" do
      assert params([]) == []
    end

    test "a map is accepted as well as a keyword list" do
      assert Filter.to_params(%{queue: "emails"}) == [queue: "emails"]
    end
  end
end
