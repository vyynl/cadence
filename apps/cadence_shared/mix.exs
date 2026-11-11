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
      # `mix test --cover` fails below this floor; Mix's 90 default is
      # deliberately not chased. The key is per app because umbrella `mix test
      # --cover` recurses into each child and reads that child's config (the
      # root `mix.exs` carries the same key for `mix test.coverage`).
      # Last full run 2026-11-11: 87.98 shared / 82.09 daemon / 82.32 server
      # (see docs/progress.md).
      test_coverage: [summary: [threshold: 80]],
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
