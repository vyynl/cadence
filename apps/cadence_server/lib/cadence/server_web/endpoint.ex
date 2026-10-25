defmodule Cadence.ServerWeb.Endpoint do
  @moduledoc """
  Server HTTP endpoint (Bandit), used by the web UI and sync API.
  """

  use Phoenix.Endpoint, otp_app: :cadence_server

  @session_options [
    store: :cookie,
    key: "_cadence_key",
    signing_salt: "cadence-session",
    same_site: "Lax",
    http_only: true
  ]

  socket("/socket", Cadence.ServerWeb.UserSocket,
    websocket: [connect_info: [:x_headers]],
    longpoll: false
  )

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Static,
    at: "/assets/vendor",
    from: {:phoenix, "priv/static"},
    only: ["phoenix.min.js"],
    gzip: false
  )

  plug(Plug.Static,
    at: "/assets/vendor",
    from: {:phoenix_live_view, "priv/static"},
    only: ["phoenix_live_view.min.js"],
    gzip: false
  )

  plug(Plug.Static, at: "/assets", from: :cadence_server, gzip: false)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)

  plug(Cadence.ServerWeb.Router)
end
