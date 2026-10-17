defmodule Cadence.ServerWeb.JSON do
  @moduledoc """
  Small JSON response helper for the server's controller-backed endpoints.
  """

  import Plug.Conn

  def json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
