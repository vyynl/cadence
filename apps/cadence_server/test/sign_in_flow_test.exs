defmodule Cadence.ServerWeb.SignInFlowTest do
  @moduledoc """
  End-to-end sign-in flows: password → TOTP challenge or enrollment → session,
  recovery codes, remember-me, generic failures, and rate limits (spec §7.4).
  """

  use Cadence.ServerWeb.ConnCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Cadence.Server.Accounts
  alias Cadence.Server.Accounts.LocalAuth
  alias Cadence.Server.Accounts.TOTP
  alias Cadence.Server.Accounts.User
  alias Cadence.Server.Accounts.UserSession
  alias Cadence.Server.Repo
  alias Cadence.ServerWeb.PasskeyTestHelpers, as: H

  @password "correct horse battery staple"

  setup %{conn: conn} do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      LocalAuth.create_user(%{
        email: "flow-#{suffix}@example.com",
        name: "Flow User",
        password: @password
      })

    {:ok, conn: init_test_session(conn, %{}), user: user, password: @password}
  end

  describe "password sign-in" do
    test "a local account without TOTP is sent to enrollment", %{conn: conn, user: user} do
      conn = post(conn, "/sign-in", %{"email" => to_string(user.email), "password" => @password})

      assert redirected_to(conn) == "/sign-in/totp/setup"
      assert get_session(conn, :totp_pending_user_id) == user.id
      refute Repo.get_by(UserSession, user_id: user.id)
    end

    test "an enrolled account is sent to the TOTP challenge", %{conn: conn, user: user} do
      {user, _secret, _codes} = enrolled_user(user)

      conn = post(conn, "/sign-in", %{"email" => to_string(user.email), "password" => @password})

      assert redirected_to(conn) == "/sign-in/totp"
      assert get_session(conn, :totp_pending_user_id) == user.id
      refute Repo.get_by(UserSession, user_id: user.id)
    end

    test "a wrong password is generic, preserves the email, and creates no session", %{
      conn: conn,
      user: user
    } do
      conn =
        post(conn, "/sign-in", %{"email" => to_string(user.email), "password" => "wrong password"})

      assert redirected_to(conn) == "/sign-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password."
      assert get_session(conn, :sign_in_email) == to_string(user.email)
      refute Repo.get_by(UserSession, user_id: user.id)

      html = conn |> get("/sign-in") |> html_response(200)
      assert html =~ "Invalid email or password."
      assert html =~ ~s(value="#{user.email}")
    end

    test "an unknown email uses the same copy", %{conn: conn} do
      conn = post(conn, "/sign-in", %{"email" => "nobody@example.com", "password" => @password})

      assert redirected_to(conn) == "/sign-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password."
    end

    test "missing fields are refused", %{conn: conn} do
      conn = post(conn, "/sign-in", %{"email" => "only@example.com"})

      assert redirected_to(conn) == "/sign-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Enter your email and password"
    end

    test "a forged POST without a CSRF token is rejected", %{conn: conn, user: user} do
      {conn, _token} = H.csrf_session(conn)
      conn = H.enable_csrf(conn)

      assert {403, _headers, _body} =
               assert_error_sent(403, fn ->
                 post(conn, "/sign-in", %{
                   "email" => to_string(user.email),
                   "password" => @password
                 })
               end)

      refute Repo.get_by(UserSession, user_id: user.id)
    end
  end

  describe "TOTP challenge" do
    test "a valid code creates a session and honours return_to", %{conn: conn, user: user} do
      {user, secret, _codes} = enrolled_user(user)
      conn = put_session(conn, :user_return_to, "/p/cadence-demo")

      conn =
        post(conn, "/sign-in", %{"email" => to_string(user.email), "password" => @password})

      conn = post(conn, "/sign-in/totp", %{"code" => NimbleTOTP.verification_code(secret)})

      assert redirected_to(conn) == "/p/cadence-demo"
      assert is_binary(get_session(conn, :user_session_token))
      assert Repo.get_by(UserSession, user_id: user.id)
    end

    test "a recovery code signs in once and is consumed", %{conn: conn, user: user} do
      {user, _secret, [code | _]} = enrolled_user(user)
      conn = post(conn, "/sign-in", %{"email" => to_string(user.email), "password" => @password})
      conn = post(conn, "/sign-in/totp", %{"code" => code})

      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Recovery code accepted"
      assert TOTP.count_unused(user) == 9
    end

    test "a wrong code keeps the pending hand-off and creates no session", %{
      conn: conn,
      user: user
    } do
      {user, _secret, _codes} = enrolled_user(user)
      conn = post(conn, "/sign-in", %{"email" => to_string(user.email), "password" => @password})
      conn = post(conn, "/sign-in/totp", %{"code" => "000000"})

      assert html_response(conn, 200) =~ "Invalid or expired code."
      refute Repo.get_by(UserSession, user_id: user.id)
    end

    test "an expired pending hand-off redirects to sign-in", %{conn: conn, user: user} do
      conn = put_session(conn, :totp_pending_user_id, user.id)
      conn = put_session(conn, :totp_pending_at, System.system_time(:second) - 600)

      conn = get(conn, "/sign-in/totp")

      assert redirected_to(conn) == "/sign-in"
      refute get_session(conn, :totp_pending_user_id)
    end

    test "remember-me survives the challenge", %{conn: conn, user: user} do
      {user, secret, _codes} = enrolled_user(user)

      conn =
        post(conn, "/sign-in", %{
          "email" => to_string(user.email),
          "password" => @password,
          "remember_me" => "true"
        })

      conn = post(conn, "/sign-in/totp", %{"code" => NimbleTOTP.verification_code(secret)})

      assert conn.resp_cookies["_cadence_remember_me"][:value]
      assert is_binary(get_session(conn, :user_session_token))
    end
  end

  describe "TOTP enrollment" do
    test "renders a QR code and confirming stores the secret and shows codes", %{
      conn: conn,
      user: user
    } do
      conn =
        post(conn, "/sign-in", %{
          "email" => to_string(user.email),
          "password" => @password,
          "remember_me" => "true"
        })

      conn = get(conn, "/sign-in/totp/setup")

      html = html_response(conn, 200)
      assert html =~ "Scan this QR code"
      assert html =~ "data:image/svg+xml;base64,"

      {:ok, pending} = Ash.get(User, user.id, domain: Accounts)
      {:ok, secret} = TOTP.get_secret(pending)

      conn = post(conn, "/sign-in/totp/setup", %{"code" => NimbleTOTP.verification_code(secret)})

      html = html_response(conn, 200)
      assert html =~ "Save your recovery codes"
      assert html =~ "I have saved these codes"
      assert html =~ to_string(user.email)
      assert conn.resp_cookies["_cadence_remember_me"][:value]
      assert length(Regex.scan(~r/<code>/, html)) == 10
      assert is_binary(get_session(conn, :user_session_token))
      assert Repo.get_by(UserSession, user_id: user.id)

      {:ok, enrolled} = Ash.get(User, user.id, domain: Accounts)
      assert TOTP.enabled?(enrolled)
      assert TOTP.count_unused(enrolled) == 10
      refute get_session(conn, :totp_pending_user_id)
    end

    test "a wrong confirmation code shows the QR again", %{conn: conn, user: user} do
      conn = post(conn, "/sign-in", %{"email" => to_string(user.email), "password" => @password})
      conn = get(conn, "/sign-in/totp/setup")
      conn = post(conn, "/sign-in/totp/setup", %{"code" => "000000"})

      html = html_response(conn, 200)
      assert html =~ "That code is not valid"
      assert html =~ "data:image/svg+xml;base64,"
      refute Repo.get_by(UserSession, user_id: user.id)
    end
  end

  describe "demo hints" do
    test "the sign-in and TOTP pages show the demo command only when enabled", %{
      conn: conn,
      user: user
    } do
      original = Application.get_env(:cadence_server, :demo_hints)
      Application.put_env(:cadence_server, :demo_hints, true)
      on_exit(fn -> Application.put_env(:cadence_server, :demo_hints, original) end)

      html = conn |> get("/sign-in") |> html_response(200)
      assert html =~ "Demo stack"
      assert html =~ "docker compose exec server mix cadence.totp"

      {user, _secret, _codes} = enrolled_user(user)
      conn = post(conn, "/sign-in", %{"email" => to_string(user.email), "password" => @password})
      html = conn |> get("/sign-in/totp") |> html_response(200)
      assert html =~ "docker compose exec server mix cadence.totp --email #{user.email}"
    end
  end

  describe "rate limits" do
    test "a second attempt for the same IP + email is refused", %{conn: conn, user: user} do
      original = Application.get_env(:cadence_server, :auth_login_account_rate_limit)
      Application.put_env(:cadence_server, :auth_login_account_rate_limit, 1)

      on_exit(fn ->
        Application.put_env(:cadence_server, :auth_login_account_rate_limit, original)
      end)

      params = %{"email" => to_string(user.email), "password" => "wrong password"}

      first = post(conn, "/sign-in", params)
      assert redirected_to(first) == "/sign-in"

      second = post(first, "/sign-in", params)
      assert redirected_to(second) == "/sign-in"
      assert Phoenix.Flash.get(second.assigns.flash, :error) =~ "Too many sign-in attempts"
    end
  end

  describe "OAuth callback" do
    test "an enrolled account goes to the challenge instead of a session", %{
      conn: conn,
      user: user
    } do
      {user, _secret, _codes} = enrolled_user(user)

      conn = Phoenix.Controller.fetch_flash(conn)
      conn = Cadence.ServerWeb.AuthController.success(conn, :sign_in, user, "ignored")

      assert redirected_to(conn) == "/sign-in/totp"
      refute Repo.get_by(UserSession, user_id: user.id)
    end
  end

  defp enrolled_user(user) do
    {:ok, user, secret} = TOTP.begin_enrollment(user)
    {:ok, user, codes} = TOTP.confirm_enrollment(user, NimbleTOTP.verification_code(secret))

    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

    {:ok, user} =
      user
      |> Ash.Changeset.for_update(:mark_totp_used, %{totp_last_used_at: past})
      |> Ash.update(domain: Accounts)

    {user, secret, codes}
  end
end
