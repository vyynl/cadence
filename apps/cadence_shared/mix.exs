defmodule Cadence.Shared.MixProject do
  use Mix.Project

  def project do
    [
      app: :cadence_shared,
      version: "1.0.0",
      elixir: "~> 1.20",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Cadence.Shared.Application, []}
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
