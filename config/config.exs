import Config

config :cadence_daemon,
  ecto_repos: [Cadence.Daemon.Repo]

import_config "#{config_env()}.exs"
