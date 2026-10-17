defmodule Cadence.ServerWeb.AuthPlug do
  @moduledoc """
  Authenticates daemon requests using a Cadence API key.

  Wraps `AshAuthentication.Strategy.ApiKey.Plug` so every `/sync/*` request gets
  `:current_user` (and, via `:set_actor`, the Ash actor) or a JSON 401.
  """

  @behaviour Plug

  @impl true
  def init(opts) do
    AshAuthentication.Strategy.ApiKey.Plug.init(
      Keyword.merge(
        [
          resource: Cadence.Server.Accounts.User,
          strategy: :api_key,
          on_error: &__MODULE__.on_error/2
        ],
        opts
      )
    )
  end

  @impl true
  def call(conn, opts), do: AshAuthentication.Strategy.ApiKey.Plug.call(conn, opts)

  @doc false
  def on_error(conn, _error) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(401, Jason.encode!(%{error: "unauthorized"}))
    |> Plug.Conn.halt()
  end
end
