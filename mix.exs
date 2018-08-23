defmodule GrncShared.Mixfile do
  use Mix.Project

  def project do
    [app: :grnc_shared,
     version: "0.1.2",
     elixir: "~> 1.3",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     deps: deps()]
  end

  # Configuration for the OTP application
  #
  # Type "mix help compile.app" for more information
  def application do
    [applications: [:logger],
     mod: {GrncShared.Application, []}]
  end

  # Dependencies can be Hex packages:
  #
  #   {:mydep, "~> 0.3.0"}
  #
  # Or git/path repositories:
  #
  #   {:mydep, git: "https://github.com/elixir-lang/mydep.git", tag: "0.1.0"}
  #
  # Type "mix help deps" for more examples and options
  defp deps do
    [
      {:cowboy, "~> 1.0.0"},
      {:plug, "> 0.8.0"},

      {:ex_doc, "~> 0.14", only: :dev},
      {:earmark, "~> 1.0", only: :dev},
      {:credo, "~> 0.4", only: [:dev, :test]},
      {:statix, github: "lexmag/statix"},
    ]
  end
end
