# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.HTTPTest do
  use ExUnit.Case, async: true

  alias Zizq.Config
  alias Zizq.HTTP

  defp config(format \\ :msgpack) do
    Config.new!(name: :http_test, url: "http://localhost:7890", format: format)
  end

  defp header(headers, name), do: List.keyfind(headers, name, 0)

  describe "build_body/2 with no body" do
    test "sends accept but no content-type" do
      assert {:ok, headers, body} = HTTP.build_body(config(), nil)

      assert body == nil
      assert header(headers, "accept") == {"accept", "application/msgpack"}

      # Content-Type would describe content that is not there. Some
      # servers and proxies route or reject on it, so a bodyless
      # request must not carry one.
      refute header(headers, "content-type")
    end

    test "accept follows the configured codec" do
      assert {:ok, headers, nil} = HTTP.build_body(config(:json), nil)
      assert header(headers, "accept") == {"accept", "application/json"}
    end
  end

  describe "build_body/2 with a body" do
    test "sends both accept and content-type" do
      assert {:ok, headers, body} = HTTP.build_body(config(), %{"a" => 1})

      assert header(headers, "accept") == {"accept", "application/msgpack"}
      assert header(headers, "content-type") == {"content-type", "application/msgpack"}
      assert IO.iodata_length(body) > 0
    end

    test "encodes with the configured codec" do
      assert {:ok, _headers, body} = HTTP.build_body(config(:json), %{"a" => 1})
      assert IO.iodata_to_binary(body) == ~s({"a":1})
    end

    test "returns the encoder's error rather than raising" do
      # Invalid UTF-8 is representable in an Elixir binary but not in
      # JSON, so this fails locally at encode time.
      assert {:error, exception} = HTTP.build_body(config(:json), %{"a" => <<0xFF>>})
      assert Exception.message(exception) =~ ~r/\S/
    end
  end
end
