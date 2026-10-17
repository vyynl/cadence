defmodule Cadence.ServerWeb.SyncController do
  @moduledoc """
  Sync API endpoints.

  Phase 2b-1 only exposes `GET /sync/me` to verify bearer-token auth; push/pull
  land in milestone 2b-2.
  """

  use Cadence.ServerWeb, :controller

  def me(conn, _params) do
    user = conn.assigns.current_user

    json(conn, 200, %{
      user_id: user.id,
      email: to_string(user.email),
      name: user.name
    })
  end
end
