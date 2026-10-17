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
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, form_html(user))
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
            |> put_resp_content_type("text/html")
            |> send_resp(201, created_html(plaintext))

          {:error, _reason} ->
            json(conn, 422, %{error: "could not create api key"})
        end
    end
  end

  defp form_html(user) do
    csrf = Plug.CSRFProtection.get_csrf_token()
    email = user.email |> to_string() |> Plug.HTML.html_escape()

    """
    <!doctype html>
    <html lang="en">
      <head><meta charset="utf-8"><title>Cadence API key</title></head>
      <body>
        <h1>Create a Cadence API key</h1>
        <p>Signed in as #{email}.</p>
        <p>The key is shown once. Store it in <code>~/.config/cadence/env</code>.</p>
        <form method="post" action="/auth/tokens">
          <input type="hidden" name="_csrf_token" value="#{csrf}">
          <label>Key name
            <input type="text" name="name" value="daemon" required>
          </label>
          <button type="submit">Create key</button>
        </form>
      </body>
    </html>
    """
  end

  defp created_html(plaintext) do
    """
    <!doctype html>
    <html lang="en">
      <head><meta charset="utf-8"><title>Cadence API key</title></head>
      <body>
        <h1>Your Cadence API key</h1>
        <p>This value is shown once. Store it now:</p>
        <pre>#{plaintext}</pre>
        <p>Put it in <code>~/.config/cadence/env</code> as <code>CAD_AUTH_TOKEN</code>.</p>
      </body>
    </html>
    """
  end
end
