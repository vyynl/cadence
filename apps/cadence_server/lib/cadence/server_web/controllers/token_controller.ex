defmodule Cadence.ServerWeb.TokenController do
  @moduledoc """
  OAuth-session-guarded personal access token issuance.

  A signed-in human visits `/auth/tokens/new`, names the daemon, and receives
  the plaintext API key exactly once. Daemons then send it as a bearer token.
  """

  use Cadence.ServerWeb, :controller

  alias Cadence.Server.Accounts

  def new(conn, _params) do
    case conn.assigns[:current_user] do
      nil ->
        json(conn, 401, %{error: "unauthorized"})

      user ->
        # Templates escape every interpolation (HEEx), so the hand-built HTML
        # strings this page used to send are gone. The explicit "new.html"
        # template form keeps rendering independent of conn.params, because the
        # controller tests call these actions directly on a bare conn.
        # Both token pages carry a CSRF token and (on create) a live PAT, so
        # every cache in the path must keep its own copy.
        conn
        |> put_resp_header("cache-control", "private, no-store")
        |> put_view(Cadence.ServerWeb.TokenHTML)
        |> render("new.html",
          layout: false,
          email: to_string(user.email),
          csrf: Plug.CSRFProtection.get_csrf_token()
        )
    end
  end

  def create(conn, params) do
    case conn.assigns[:current_user] do
      nil ->
        json(conn, 401, %{error: "unauthorized"})

      user ->
        name = Map.get(params, "name", "daemon")

        case Accounts.create_api_key(user, name) do
          {:ok, api_key} ->
            plaintext = api_key.__metadata__.plaintext_api_key

            conn
            |> put_resp_header("cache-control", "private, no-store")
            |> put_status(201)
            |> put_view(Cadence.ServerWeb.TokenHTML)
            |> render("create.html", layout: false, plaintext: plaintext)

          {:error, _reason} ->
            json(conn, 422, %{error: "could not create api key"})
        end
    end
  end
end
