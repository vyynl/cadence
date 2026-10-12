defmodule Cadence.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      elixir: "~> 1.18",
      deps: deps()
    ]
  end

  defp deps do
    []
  end
end
