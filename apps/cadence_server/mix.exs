defmodule Cadence.Server.MixProject do
  use Mix.Project

  def project do
    [
      app: :cadence_server,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
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
      {:hammer, "~> 7.5"},
      {:sourceror, "~> 1.7", only: [:dev, :test]},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:slipstream, "~> 1.2", only: [:dev, :test]}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
