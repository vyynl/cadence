defmodule Cadence.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "1.0.0",
      start_permanent: Mix.env() == :prod,
      elixir: "~> 1.20",
      # Coverage floor for `mix test.coverage`, which aggregates from the
      # umbrella root and reads *this* project's config. Umbrella `mix test
      # --cover` ignores this key (it recurses into each child, which carries
      # the same `summary: [threshold: 80]`), so both levels are required to
      # keep a single 80% floor across every coverage entry point.
      test_coverage: [summary: [threshold: 80]],
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
