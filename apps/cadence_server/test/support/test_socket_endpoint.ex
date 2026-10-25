defmodule Cadence.ServerWeb.TestSocketEndpoint do
  @moduledoc """
  Test-only endpoint for real websocket integration tests.

  Started on a free local port without disturbing the main test endpoint.
  """

  use Phoenix.Endpoint, otp_app: :cadence_server

  socket("/socket", Cadence.ServerWeb.UserSocket,
    websocket: [connect_info: [:x_headers]],
    longpoll: false
  )
end
