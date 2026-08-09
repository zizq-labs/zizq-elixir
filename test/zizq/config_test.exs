# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

defmodule Zizq.ConfigTest do
  use ExUnit.Case, async: true

  alias Zizq.Config

  @base [name: :cfg_test, url: "http://localhost:7890"]

  describe "new!/1" do
    test "applies defaults" do
      config = Config.new!(@base)

      assert config.name == :cfg_test
      assert Config.url(config) == "http://localhost:7890"
      assert {config.uri.scheme, config.uri.host, config.uri.port} == {"http", "localhost", 7890}
      assert config.codec == Zizq.Codec.MessagePack
      assert config.pool_count == 1
      assert config.connect_timeout == 5_000
      assert config.receive_timeout == 15_000
    end

    test "derives a Finch name scoped to the client" do
      assert Config.new!(@base).finch_name == :"Elixir.cfg_test.Finch"
      assert Config.new!(Keyword.put(@base, :name, MyApp.Zizq)).finch_name == MyApp.Zizq.Finch
    end

    test "resolves :format to a codec module" do
      assert Config.new!(Keyword.put(@base, :format, :json)).codec == Zizq.Codec.JSON
      assert Config.new!(Keyword.put(@base, :format, :msgpack)).codec == Zizq.Codec.MessagePack

      assert Config.new!(Keyword.put(@base, :format, Zizq.Codec.JSON)).codec ==
               Zizq.Codec.JSON
    end

    test "rejects an unknown format" do
      assert_raise ArgumentError, ~r/Zizq.Codec/, fn ->
        Config.new!(Keyword.put(@base, :format, :yaml))
      end
    end

    test "requires :name and :url" do
      assert_raise NimbleOptions.ValidationError, ~r/:name/, fn ->
        Config.new!(url: "http://localhost:7890")
      end

      assert_raise NimbleOptions.ValidationError, ~r/:url/, fn ->
        Config.new!(name: :cfg_test)
      end
    end

    test "rejects unknown options rather than ignoring them" do
      assert_raise NimbleOptions.ValidationError, ~r/porl_count|not supported/, fn ->
        Config.new!(Keyword.put(@base, :porl_count, 4))
      end
    end

    # A double slash in a path is not merely cosmetic — the server
    # routes on exact paths, so `//jobs` would 404.
    test "strips trailing slashes from the path" do
      for url <- ["http://localhost:7890/", "http://localhost:7890///"] do
        assert Config.new!(Keyword.put(@base, :url, url)).uri.path == nil
      end

      assert Config.new!(Keyword.put(@base, :url, "https://example.com/zizq/")).uri.path ==
               "/zizq"
    end

    test "keeps a path as a prefix, for proxied deployments" do
      config = Config.new!(Keyword.put(@base, :url, "https://example.com/zizq"))

      assert config.uri.path == "/zizq"
      assert Config.url(config) == "https://example.com/zizq"
    end

    # Finch and Mint both want the parsed form, so a caller who already
    # has one should not have to stringify it just to be re-parsed.
    test "accepts a URI as well as a string" do
      from_string = Config.new!(Keyword.put(@base, :url, "https://example.com/zizq"))
      from_uri = Config.new!(Keyword.put(@base, :url, URI.parse("https://example.com/zizq")))

      assert from_uri.uri == from_string.uri
    end

    # Silently discarding these would hide a mistake; a query string on
    # a base URL means the caller expected it to be sent.
    test "rejects a base URL carrying a query, fragment or userinfo" do
      for url <- [
            "http://localhost:7890?foo=bar",
            "http://localhost:7890#frag",
            "http://user:pass@localhost:7890"
          ] do
        assert_raise ArgumentError, ~r/base URL/, fn ->
          Config.new!(Keyword.put(@base, :url, url))
        end
      end
    end

    test "rejects a URI missing a scheme or host" do
      for url <- [URI.parse("/jobs"), URI.parse("localhost:7890")] do
        assert_raise ArgumentError, ~r/http or https/, fn ->
          Config.new!(Keyword.put(@base, :url, url))
        end
      end
    end

    test "rejects URLs that aren't usable http(s) endpoints" do
      for url <- ["not a url", "ftp://example.com", "/jobs", "localhost:7890"] do
        assert_raise ArgumentError, ~r/http or https/, fn ->
          Config.new!(Keyword.put(@base, :url, url))
        end
      end
    end
  end

  describe "fetch!/1" do
    test "raises an actionable error when no such client is running" do
      error =
        assert_raise ArgumentError, fn ->
          Config.fetch!(:definitely_not_running)
        end

      assert Exception.message(error) =~ "no Zizq client named :definitely_not_running"
      # The message should show how to fix it, not just what broke.
      assert Exception.message(error) =~ "children = ["
    end

    test "round-trips through put/delete" do
      config = Config.new!(Keyword.put(@base, :name, :cfg_round_trip))
      on_exit(fn -> Config.delete(:cfg_round_trip) end)

      assert :ok = Config.put(config)
      assert Config.fetch!(:cfg_round_trip) == config

      assert Config.delete(:cfg_round_trip)

      assert_raise ArgumentError, fn -> Config.fetch!(:cfg_round_trip) end
    end
  end
end
