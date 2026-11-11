defmodule Cadence.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "1.0.0",
      start_permanent: Mix.env() == :prod,
      elixir: "~> 1.20",
      deps: deps(),
      releases: releases()
    ]
  end

  # The production artifacts (spec §12.8). The server release is `cadence` so
  # the documented command is `bin/cadence` (§12.7); the daemon release is
  # `cadence_daemon` (8b). Each release starts only its own application tree, so
  # the daemon never ships Phoenix and the server never ships the watcher.
  defp releases do
    [
      cadence: [
        applications: [cadence_server: :permanent],
        include_executables_for: [:unix],
        strip_beams: true
      ],
      cadence_daemon: [
        applications: [cadence_daemon: :permanent],
        include_executables_for: [:unix],
        strip_beams: true,
        # `rel/daemon/env.sh.eex` turns Erlang distribution off for the daemon
        # only (no epmd, cookie, or fixed node name). The server release keeps
        # Mix's default.
        rel_templates_path: "rel/daemon"
      ]
    ]
  end

  defp deps do
    []
  end
end
