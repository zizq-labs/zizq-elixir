defmodule Zizq.MixProject do
  use Mix.Project

  @version "0.6.0-alpha.4"
  @source_url "https://github.com/zizq-labs/zizq-elixir"

  def project do
    [
      app: :zizq,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      name: "Zizq",
      source_url: @source_url,
      homepage_url: "https://zizq.io"
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # 0.23 or newer: 0.23.0 fixed a race when dynamically starting
      # pool supervisors that could return `:pool_not_available` while
      # workers were still registering. `~> 0.21` would let a consumer
      # resolve back onto that bug.
      {:finch, "~> 0.23"},
      {:msgpax, "~> 2.4"},
      {:nimble_options, "~> 1.1"},

      # Test-only fake server. Bandit rather than the more usual Bypass
      # because Bypass is Cowboy-backed and HTTP/1.1 only, while this
      # client's pool is h2c-exclusive. Bypass literally cannot answer
      # it. Bandit serves HTTP/2 prior-knowledge on a plain `:http`
      # listener, so tests exercise the same transport as production.
      {:bandit, "~> 1.0", only: :test},

      # Pulled in by Finch, but pinned explicitly: CVE-2026-48862 is
      # unbounded `conn.streams` growth via unenforced PUSH_PROMISE
      # concurrency over a long-lived HTTP/2 connection — precisely the
      # shape of the `/jobs/take` stream. Fixed in 1.9.0.
      {:mint, "~> 1.9"}
    ]
  end

  defp description do
    "Official Elixir client for the Zizq job queue server"
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "Website" => "https://zizq.io",
        "Documentation" => "https://zizq.io/docs/clients/elixir/",
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end
end
