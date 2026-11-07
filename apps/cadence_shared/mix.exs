defmodule Cadence.Shared.MixProject do
  use Mix.Project

  def project do
    [
      app: :cadence_shared,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ecto, "~> 3.14"},
      {:jason, "~> 1.4"},
      {:libgraph, "~> 0.16.0"},
      {:axiom_ai, "~> 0.1.14"},
      {:hammer, "~> 7.5"},
      {:yaml_elixir, "~> 2.12"}
    ]
  end
end
