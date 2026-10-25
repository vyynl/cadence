import Config

config :cadence_daemon,
  ecto_repos: [Cadence.Daemon.Repo]

config :cadence_server,
  ecto_repos: [Cadence.Server.Repo],
  ash_domains: [Cadence.Server.Accounts]

config :cadence_server, Cadence.ServerWeb.Endpoint,
  url: [host: "localhost"],
  pubsub_server: Cadence.Server.PubSub,
  render_errors: [
    formats: [html: Cadence.ServerWeb.ErrorHTML, json: Cadence.ServerWeb.ErrorJSON],
    layout: [html: {Cadence.ServerWeb.Layouts, :app}]
  ]

config :phoenix, :json_library, Jason

config :ash, default_string_length_count: :codepoints

import_config "#{config_env()}.exs"
