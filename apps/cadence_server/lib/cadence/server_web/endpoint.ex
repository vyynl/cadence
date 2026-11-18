defmodule Cadence.ServerWeb.Endpoint do
  @moduledoc """
  Server HTTP endpoint (Bandit), used by the web UI and sync API.
  """

  use Phoenix.Endpoint, otp_app: :cadence_server

  # The LiveView socket only reads the session cookie, which ignores the
  # `Secure` flag, so the static options are enough here. The HTTP pipeline runs
  # `Cadence.ServerWeb.Session`, which rebuilds the options per request so a
  # public HTTPS origin can coexist with a private sign-in address (§12.9).
  @session_options Cadence.ServerWeb.SessionOptions.base()

  socket("/socket", Cadence.ServerWeb.UserSocket,
    websocket: [connect_info: [:x_headers]],
    longpoll: false
  )

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false
  )

  plug(Plug.RequestId)

  plug(Plug.Telemetry,
    event_prefix: [:phoenix, :endpoint],
    log: {__MODULE__, :log_level, []}
  )

  @doc false
  # Proposal URLs are capability links: the token must never reach access logs.
  # `false` suppresses the default Phoenix request log for that path.
  def log_level(%{path_info: ["proposals" | _rest]}), do: false
  def log_level(_conn), do: :info

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

  plug(Cadence.ServerWeb.Parsers)

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Cadence.ServerWeb.Session)

  plug(Cadence.ServerWeb.Router)
end
