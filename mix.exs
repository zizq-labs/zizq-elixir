defmodule Zizq.MixProject do
  use Mix.Project

  @version "0.6.0-alpha.1"
  @source_url "https://github.com/zizq-labs/zizq-elixir"

  def project do
    [
      app: :zizq,
      version: @version,
      elixir: "~> 1.18",
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

  defp deps do
    [
      {:msgpax, "~> 2.4"}
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
