defmodule Cadence.ServerWeb.Endpoint do
  @moduledoc """
  Server HTTP endpoint (Bandit), used by the web UI and sync API.
  """

  use Phoenix.Endpoint, otp_app: :cadence_server

  socket("/socket", Cadence.ServerWeb.UserSocket,
    websocket: [connect_info: [:x_headers]],
    longpoll: false
  )

  @session_options [
    store: :cookie,
    key: "_cadence_key",
    signing_salt: "cadence-session",
    same_site: "Lax",
    http_only: true
  ]

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

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
