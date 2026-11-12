defmodule Cadence.ServerWeb.SignInController do
  @moduledoc """
  Cadence-owned email/password sign-in (spec §7.4).

  A correct password does not create a session when the account has TOTP
  enabled (challenge) or when a local account still needs to enroll. The
  pending hand-off is short-lived and lives only in the signed session.

  OAuth request links and the passkey CTA are secondary methods. Every failure
  to authenticate uses the same generic copy, and the limiter is keyed per IP
  and per IP+email.
  """

  use Cadence.ServerWeb, :controller

  alias Cadence.Server.Accounts.LocalAuth
  alias Cadence.Server.Accounts.TOTP
  alias Cadence.Server.Accounts.User
  alias Cadence.Server.AuthRateLimit
  alias Cadence.Server.Passkeys.Config
  alias Cadence.ServerWeb.AuthProviders
  alias Cadence.ServerWeb.PendingAuth
  alias Cadence.ServerWeb.ReturnTo
  alias Cadence.ServerWeb.UserAuth

  @generic_failure "Invalid email or password."

  def new(conn, params) do
    return_to = ReturnTo.safe(Map.get(params, "return_to") || get_session(conn, :user_return_to))
    conn = ReturnTo.store(conn, return_to)
    sudo? = Map.get(params, "sudo") == "1"
    email = get_session(conn, :sign_in_email)
    conn = delete_session(conn, :sign_in_email)

    if conn.assigns[:current_user] && not sudo? do
      redirect(conn, to: return_to)
    else
      render(conn, :new,
        page_title: "Sign in · Cadence",
        email: email,
        return_to: return_to,
        sudo?: sudo?,
        passkeys_enabled?: Config.enabled?(),
        oauth_providers: AuthProviders.configured(),
        demo_hints?: demo_hints?()
      )
    end
  end

  def create(conn, %{"email" => email, "password" => password} = params)
      when is_binary(email) and is_binary(password) do
    if AuthRateLimit.allow_login?(client_ip(conn), email) do
      authenticate(conn, email, password, params)
    else
      conn
      |> put_flash(:error, "Too many sign-in attempts. Try again in a minute.")
      |> redirect(to: "/sign-in")
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Enter your email and password.")
    |> redirect(to: "/sign-in")
  end

  defp authenticate(conn, email, password, params) do
    case LocalAuth.get_user_by_email_and_password(email, password) do
      nil ->
        conn
        |> put_flash(:error, @generic_failure)
        |> put_session(:sign_in_email, String.slice(email, 0, 160))
        |> redirect(to: "/sign-in")

      %User{} = user ->
        start_sign_in(conn, user, params)
    end
  end

  defp start_sign_in(conn, %User{} = user, params) do
    cond do
      TOTP.enabled?(user) ->
        conn
        |> PendingAuth.put(user, remember_me: remember_me?(params))
        |> put_flash(:info, "Enter the code from your authenticator app.")
        |> redirect(to: "/sign-in/totp")

      local_account_without_totp?(user) ->
        conn
        |> PendingAuth.put(user, remember_me: remember_me?(params))
        |> put_flash(:info, "Set up two-factor authentication before using Cadence.")
        |> redirect(to: "/sign-in/totp/setup")

      true ->
        UserAuth.log_in_and_redirect(conn, user, remember_me: remember_me?(params))
    end
  end

  defp local_account_without_totp?(%User{hashed_password: password}) do
    is_binary(password) and
      Application.get_env(:cadence_server, :auth_totp_required, true) == true
  end

  defp remember_me?(params), do: Map.get(params, "remember_me") in [true, "true", "on", "1"]

  defp demo_hints?, do: Application.get_env(:cadence_server, :demo_hints, false) == true

  defp client_ip(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end
end
