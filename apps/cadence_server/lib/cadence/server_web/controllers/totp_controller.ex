defmodule Cadence.ServerWeb.TotpController do
  @moduledoc """
  The second-factor challenge for password and OAuth sign-ins (spec §7.4).

  Only a valid pending hand-off (5 minutes) can reach this page. TOTP and
  recovery-code attempts share a per-user rate limit and the same generic
  failure copy.
  """

  use Cadence.ServerWeb, :controller

  alias Cadence.Server.Accounts.TOTP
  alias Cadence.Server.AuthRateLimit
  alias Cadence.ServerWeb.PendingAuth
  alias Cadence.ServerWeb.UserAuth

  def new(conn, _params) do
    case PendingAuth.fetch(conn) do
      {:ok, user} ->
        render(conn, :new,
          page_title: "Two-factor authentication · Cadence",
          email: to_string(user.email),
          error: nil,
          demo_hints?: demo_hints?()
        )

      :error ->
        expired(conn)
    end
  end

  def create(conn, %{"code" => code}) when is_binary(code) do
    case PendingAuth.fetch(conn) do
      {:ok, user} ->
        verify(conn, user, code)

      :error ->
        expired(conn)
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Enter the six-digit code from your authenticator app.")
    |> redirect(to: "/sign-in/totp")
  end

  defp verify(conn, user, code) do
    if AuthRateLimit.allow_totp?(user.id) do
      case TOTP.verify_login(user, code) do
        {:ok, :totp} ->
          UserAuth.log_in_and_redirect(conn, user,
            remember_me: PendingAuth.remember_me?(conn),
            flash: "Signed in."
          )

        {:ok, :recovery} ->
          UserAuth.log_in_and_redirect(conn, user,
            remember_me: PendingAuth.remember_me?(conn),
            flash: "Recovery code accepted. Generate new recovery codes soon."
          )

        :error ->
          conn
          |> put_flash(:error, "Invalid or expired code.")
          |> render(:new,
            page_title: "Two-factor authentication · Cadence",
            email: to_string(user.email),
            error: "Invalid or expired code.",
            demo_hints?: demo_hints?()
          )
      end
    else
      conn
      |> put_flash(:error, "Too many verification attempts. Try again later.")
      |> render(:new,
        page_title: "Two-factor authentication · Cadence",
        email: to_string(user.email),
        error: "Too many attempts.",
        demo_hints?: demo_hints?()
      )
    end
  end

  defp expired(conn) do
    conn
    |> PendingAuth.clear()
    |> put_flash(:error, "Your sign-in expired. Please sign in again.")
    |> redirect(to: "/sign-in")
  end

  defp demo_hints?, do: Application.get_env(:cadence_server, :demo_hints, false) == true
end
