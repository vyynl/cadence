defmodule Cadence.ServerWeb.AuthController do
  @moduledoc """
  OAuth callback controller and sign-out endpoint.

  AshAuthentication still authenticates the OAuth callback; the resulting
  browser session is Cadence-owned (`Cadence.ServerWeb.UserAuth`) so it can be
  revoked, rotated, and log out LiveViews. An account with TOTP enrolled (or a
  local password account that has not enrolled) goes through the same pending
  second-factor hand-off as a password sign-in.
  """

  use Cadence.ServerWeb, :controller
  use AshAuthentication.Phoenix.Controller

  alias Cadence.Server.Accounts.TOTP
  alias Cadence.Server.Accounts.User
  alias Cadence.ServerWeb.PendingAuth
  alias Cadence.ServerWeb.UserAuth

  def success(conn, _activity, user, _token) do
    cond do
      TOTP.enabled?(user) ->
        conn
        |> PendingAuth.put(user)
        |> put_flash(:info, "Enter the code from your authenticator app.")
        |> redirect(to: "/sign-in/totp")

      local_account_without_totp?(user) ->
        conn
        |> PendingAuth.put(user)
        |> put_flash(:info, "Set up two-factor authentication before using Cadence.")
        |> redirect(to: "/sign-in/totp/setup")

      true ->
        UserAuth.log_in_and_redirect(conn, user)
    end
  end

  def failure(conn, _activity, _reason) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(401, "Authentication failed")
  end

  def sign_out(conn, _params) do
    conn
    |> UserAuth.log_out()
    |> put_flash(:info, "Signed out.")
    |> redirect(to: "/")
  end

  defp local_account_without_totp?(%User{hashed_password: password}) do
    is_binary(password) and
      Application.get_env(:cadence_server, :auth_totp_required, true) == true
  end
end
