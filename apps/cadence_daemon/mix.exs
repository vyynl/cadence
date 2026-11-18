defmodule Cadence.Daemon.MixProject do
  use Mix.Project

  def project do
    [
      app: :cadence_daemon,
      version: "1.1.0",
      elixir: "~> 1.20",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      # `mix test --cover` fails below this floor; Mix's 90 default is
      # deliberately not chased. The key is per app because umbrella `mix test
      # --cover` recurses into each child and reads that child's config (the
      # root `mix.exs` carries the same key for `mix test.coverage`).
      test_coverage: [summary: [threshold: 80]],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Cadence.Daemon.Application, []}
    ]
  end

  defp deps do
    [
      {:cadence_shared, in_umbrella: true},
      {:ecto, "~> 3.14"},
      {:ecto_sql, "~> 3.14"},
      {:ecto_sqlite3, "~> 0.25"},
      {:file_system, "~> 1.1"},
      {:req, "~> 0.7.5"},
      {:bandit, "~> 1.12"},
      {:plug, "~> 1.20"},
      {:hammer, "~> 7.5"},
      {:jason, "~> 1.4"},
      {:slipstream, "~> 1.2"},
      {:ex_ratatui, "~> 0.21"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
