defmodule Cadence.Daemon.MixProject do
  use Mix.Project

  def project do
    [
      app: :cadence_daemon,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
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
      {:slipstream, "~> 1.2"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
