defmodule Cadence.ServerWeb.TotpSetupController do
  @moduledoc """
  Forced TOTP enrollment for a local password account (spec §7.4).

  The pending password sign-in can only reach this page. Enrollment is
  compare-and-set, so two open tabs show the same QR code, and a confirmed
  secret is never replaced. Confirming a code creates the real session and
  shows the one-time recovery codes.
  """

  use Cadence.ServerWeb, :controller

  alias Cadence.Server.Accounts.TOTP
  alias Cadence.Server.AuthRateLimit
  alias Cadence.ServerWeb.PendingAuth
  alias Cadence.ServerWeb.UserAuth

  def new(conn, _params) do
    case PendingAuth.fetch(conn) do
      {:ok, user} ->
        if TOTP.enabled?(user) do
          redirect(conn, to: "/sign-in/totp")
        else
          begin_enrollment(conn, user, nil)
        end

      :error ->
        expired(conn)
    end
  end

  def create(conn, %{"code" => code}) when is_binary(code) do
    case PendingAuth.fetch(conn) do
      {:ok, user} ->
        confirm(conn, user, code)

      :error ->
        expired(conn)
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Enter the six-digit code from your authenticator app.")
    |> redirect(to: "/sign-in/totp/setup")
  end

  defp begin_enrollment(conn, user, error) do
    case TOTP.begin_enrollment(user) do
      {:ok, user, secret} ->
        render(conn, :new,
          page_title: "Set up two-factor authentication · Cadence",
          email: to_string(user.email),
          secret: TOTP.format_secret(secret),
          qr_data_uri: TOTP.qr_data_uri(user, secret),
          error: error
        )

      :error ->
        conn
        |> PendingAuth.clear()
        |> put_flash(:error, "Could not start two-factor enrollment. Please sign in again.")
        |> redirect(to: "/sign-in")
    end
  end

  defp confirm(conn, user, code) do
    if AuthRateLimit.allow_totp?(user.id) do
      case TOTP.confirm_enrollment(user, code) do
        {:ok, updated, codes} ->
          {conn, session} =
            UserAuth.log_in(conn, updated, remember_me: PendingAuth.remember_me?(conn))

          conn
          |> assign(:current_user, updated)
          |> assign(:current_session, session)
          |> put_flash(:info, "Two-factor authentication enabled.")
          |> render(:recovery_codes,
            page_title: "Recovery codes · Cadence",
            codes: codes
          )

        {:error, :invalid_code} ->
          begin_enrollment(conn, user, "That code is not valid. Check your clock and try again.")

        {:error, _reason} ->
          conn
          |> PendingAuth.clear()
          |> put_flash(
            :error,
            "Could not enable two-factor authentication. Please sign in again."
          )
          |> redirect(to: "/sign-in")
      end
    else
      begin_enrollment(conn, user, "Too many attempts. Try again later.")
    end
  end

  defp expired(conn) do
    conn
    |> PendingAuth.clear()
    |> put_flash(:error, "Your sign-in expired. Please sign in again.")
    |> redirect(to: "/sign-in")
  end
end
