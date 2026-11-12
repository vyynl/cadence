defmodule Cadence.ServerWeb.SignInPageTest do
  @moduledoc """
  The Cadence-owned `/sign-in` page, the OAuth/passkey entry points, and the
  header Account link (spec §7.4).
  """

  use Cadence.ServerWeb.ConnCase, async: false

  import Phoenix.ConnTest

  alias Cadence.Server.Accounts.User
  alias Cadence.ServerWeb.PasskeyTestHelpers, as: H

  test "renders the password form and the passkey CTA", %{conn: conn} do
    html =
      conn
      |> get("/sign-in")
      |> html_response(200)

    assert html =~ "Sign in to Cadence"
    assert html =~ ~s(action="/sign-in")
    assert html =~ ~s(name="email")
    assert html =~ ~s(name="password")
    assert html =~ ~s(name="remember_me")
    assert html =~ "Sign in with a security key or passkey"
    assert html =~ "/auth/passkeys/sign-in"
    refute html =~ "/auth/user/demo"
  end

  test "renders only the OAuth providers that are configured", %{conn: conn} do
    html = conn |> get("/sign-in") |> html_response(200)
    refute html =~ "/auth/user/github"

    original = Application.get_env(:cadence_server, :oauth)

    Application.put_env(:cadence_server, :oauth,
      github: [client_id: "github-id", client_secret: "secret"],
      google: [client_id: "google-id", client_secret: "secret"]
    )

    on_exit(fn -> Application.put_env(:cadence_server, :oauth, original) end)

    html = build_conn() |> get("/sign-in") |> html_response(200)
    assert html =~ "/auth/user/github"
    assert html =~ "/auth/user/google"
    assert html =~ "Continue with GitHub"
  end

  test "hides the passkey CTA when CAD_WEBAUTHN_ENABLED=false", %{conn: conn} do
    with_webauthn_config(enabled: false)

    html =
      conn
      |> get("/sign-in")
      |> html_response(200)

    refute html =~ "Sign in with a security key or passkey"
    refute html =~ "/auth/passkeys/sign-in"
  end

  test "a signed-in user is redirected away from the sign-in page", %{conn: conn} do
    user = Ash.Seed.seed!(User, %{email: "already@example.com", name: "Already"})

    conn =
      conn
      |> H.signed_conn(user)
      |> get("/sign-in")

    assert redirected_to(conn) == "/"
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

  test "serves the favicon and links the SVG mark", %{conn: conn} do
    icon = get(conn, "/favicon.ico")

    assert response(icon, 200)
    assert get_resp_header(icon, "content-type") |> hd() =~ "image/svg+xml"

    html = build_conn() |> get("/sign-in") |> html_response(200)
    assert html =~ ~s(rel="icon")
    assert html =~ "/assets/favicon.svg"
    assert html =~ "brand-logo"
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
