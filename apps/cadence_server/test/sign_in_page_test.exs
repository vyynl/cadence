defmodule Cadence.ServerWeb.SignInPageTest do
  @moduledoc """
  The Cadence-owned `/sign-in` page and the header Account link (plan §7.6,
  §7.8). The existing OAuth and demo-password strategies must keep rendering.
  """

  use Cadence.ServerWeb.ConnCase, async: false

  import Phoenix.ConnTest

  alias Cadence.Server.Accounts.User
  alias Cadence.ServerWeb.PasskeyTestHelpers, as: H

  test "renders the passkey CTA alongside the existing strategies", %{conn: conn} do
    html =
      conn
      |> get("/sign-in")
      |> html_response(200)

    assert html =~ "Sign in with a security key or passkey"
    assert html =~ "/auth/passkeys/sign-in"
    assert html =~ "Use a phone"

    # GitHub and Google OAuth request phases.
    assert html =~ "/auth/user/github"
    assert html =~ "/auth/user/google"

    # The compile-gated demo password strategy is present in the test build.
    assert html =~ "/auth/user/demo"
  end

  test "hides the passkey CTA when CAD_WEBAUTHN_ENABLED=false", %{conn: conn} do
    with_webauthn_config(enabled: false)

    html =
      conn
      |> get("/sign-in")
      |> html_response(200)

    refute html =~ "Sign in with a security key or passkey"
    refute html =~ "/auth/passkeys/sign-in"
    assert html =~ "/auth/user/github"
  end

  test "shows the Account link to a signed-in user when enabled", %{conn: conn} do
    user = Ash.Seed.seed!(User, %{email: "nav@example.com", name: "Nav"})

    html =
      conn
      |> H.signed_conn(user)
      |> get("/")
      |> html_response(200)

    assert html =~ ~s(href="/account/security")
  end

  test "hides the Account link when passkeys are disabled", %{conn: conn} do
    with_webauthn_config(enabled: false)
    user = Ash.Seed.seed!(User, %{email: "nav-off@example.com", name: "Nav Off"})

    html =
      conn
      |> H.signed_conn(user)
      |> get("/")
      |> html_response(200)

    refute html =~ ~s(href="/account/security")
  end

  test "the app CSP still allows only same-origin scripts", %{conn: conn} do
    conn = get(conn, "/auth/passkeys/sign-in")

    assert [policy] = get_resp_header(conn, "content-security-policy")
    assert policy =~ "script-src 'self'"
    refute policy =~ "script-src 'self' 'unsafe-inline'"
  end

  defp with_webauthn_config(overrides) do
    original = Application.get_env(:cadence_server, :webauthn)
    Application.put_env(:cadence_server, :webauthn, Keyword.merge(original, overrides))
    on_exit(fn -> Application.put_env(:cadence_server, :webauthn, original) end)
    :ok
  end
end
