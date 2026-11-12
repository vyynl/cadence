defmodule Cadence.ServerWeb.Endpoint do
  @moduledoc """
  Server HTTP endpoint (Bandit), used by the web UI and sync API.
  """

  use Phoenix.Endpoint, otp_app: :cadence_server

  # `Plug.Session` options are baked into the endpoint at compile time. The
  # `secure` flag is derived from the build environment rather than a runtime
  # variable: a `MIX_ENV=prod` release is served over HTTPS (§12.9) and always
  # gets `secure: true`; dev, test, and the demo image stay on
  # `http://localhost`, which both the browser and WebAuthn treat as a secure
  # context (§7.4). A prod release served over plain HTTP is a misconfiguration,
  # not a supported mode.
  @session_options Cadence.ServerWeb.SessionOptions.cookie(Mix.env())

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
  plug(Plug.Session, @session_options)

  plug(Cadence.ServerWeb.Router)
end
