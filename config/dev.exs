import Config

config :cadence_server, Cadence.ServerWeb.Endpoint,
  debug_errors: true,
  code_reloader: false

config :logger, level: :debug
