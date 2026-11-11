defmodule Cadence.Server.MixProject do
  use Mix.Project

  def project do
    [
      app: :cadence_server,
      version: "1.0.0",
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
      # Last full run 2026-11-11: 87.98 shared / 82.09 daemon / 82.32 server
      # (see docs/progress.md).
      test_coverage: [summary: [threshold: 80]],
      deps: deps()
    ]
  end

  def application do
    [
      # :inets/:ssl back Tesla's httpc adapter, which the Docker API client uses
      # when no other adapter is configured (spec §8, §11).
      extra_applications: [:logger, :inets, :ssl],
      mod: {Cadence.Server.Application, []}
    ]
  end

  defp deps do
    [
      {:cadence_shared, in_umbrella: true},
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_pubsub, "~> 2.4"},
      {:mdex, "~> 0.14"},
      {:bandit, "~> 1.13"},
      {:plug, "~> 1.20"},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.22"},
      {:jason, "~> 1.4"},
      {:ash, "~> 3.36"},
      {:ash_postgres, "~> 2.14"},
      {:ash_authentication, "~> 4.15"},
      {:ash_authentication_phoenix, "~> 2.17"},
      {:bcrypt_elixir, "~> 3.0"},
      {:ex_docker_api, "~> 1.55"},
      {:hammer, "~> 7.5"},
      {:sourceror, "~> 1.7", only: [:dev, :test]},
      {:sobelow, "~> 0.18", only: [:dev, :test], runtime: false},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:slipstream, "~> 1.2", only: [:dev, :test]}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
