defmodule Cadence.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      elixir: "~> 1.20",
      deps: deps(),
      releases: releases()
    ]
  end

  # The production server artifact (spec §12.8). The release name is `cadence`
  # so the documented command is `bin/cadence` (§12.7). `cadence_shared` comes
  # in as a runtime dependency of `cadence_server`; the daemon is 8b.
  defp releases do
    [
      cadence: [
        applications: [cadence_server: :permanent],
        include_executables_for: [:unix],
        strip_beams: true
      ]
    ]
  end

  defp deps do
    []
  end
end
