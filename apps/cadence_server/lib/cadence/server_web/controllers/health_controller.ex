defmodule Cadence.ServerWeb.HealthController do
  @moduledoc """
  Unauthenticated liveness endpoint.
  """

  use Cadence.ServerWeb, :controller

  def index(conn, _params) do
    json(conn, 200, %{status: "ok"})
  end
end
