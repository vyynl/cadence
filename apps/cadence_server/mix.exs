defmodule Cadence.Server.MixProject do
  use Mix.Project

  def project do
    [
      app: :cadence_server,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
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
      {:cadence_shared, in_umbrella: true}
    ]
  end
end
