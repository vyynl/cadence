import Config

# Demo/dev ergonomics: modules recompile on the next request, so template and
# source edits appear after a browser refresh. Static CSS is read from
# `priv/static/css` on every request, so the container bind-mount makes style
# edits visible on refresh too.
#
# `live_reload` (push-based reload without a refresh) would need the
# `phoenix_live_reload` dependency, which is not in spec §11; refresh-based
# reload is enough for the demo stack.
config :cadence_server, Cadence.ServerWeb.Endpoint,
  debug_errors: true,
  code_reloader: true

config :logger, level: :debug
