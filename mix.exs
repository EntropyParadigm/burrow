defmodule Burrow.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/EntropyParadigm/burrow"

  def project do
    [
      app: :burrow,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript(),

      # Hex
      description: "Fast, secure TCP/UDP tunneling in Elixir",
      package: package(),

      # Docs
      name: "Burrow",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl],
      mod: {Burrow.Application, []}
    ]
  end

  defp deps do
    [
      # TCP Server
      {:thousand_island, "~> 1.0"},

      # JSON (for config files)
      {:jason, "~> 1.4"},

      # TOML config parsing
      {:toml, "~> 0.7"},

      # Telemetry
      {:telemetry, "~> 1.2"},

      # CLI argument parsing
      {:optimus, "~> 0.5"},

      # Password hashing (Argon2)
      {:argon2_elixir, "~> 4.0"},

      # Documentation
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp escript do
    [
      main_module: Burrow.CLI,
      name: "burrow"
    ]
  end

  defp package do
    [
      maintainers: ["EntropyParadigm"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}"
    ]
  end
end
