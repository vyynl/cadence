defmodule Cadence.ServerWeb.PasskeySignInTest do
  @moduledoc """
  Passkey sign-in page, ceremony, session, and generic failures (plan §7.6).
  """

  use Cadence.ServerWeb.ConnCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Cadence.Server.Accounts
  alias Cadence.Server.Accounts.User
  alias Cadence.Server.Accounts.WebAuthnCredential
  alias Cadence.Server.FakeAuthenticator
  alias Cadence.Server.Passkeys
  alias Cadence.ServerWeb.PasskeyTestHelpers, as: H

  @generic "That key could not sign you in. Try again or use another sign-in method."

  setup do
    suffix = System.unique_integer([:positive])

    user =
      Ash.Seed.seed!(User, %{
        email: "signin-#{suffix}@example.com",
        name: "Sign In"
      })

    {:ok, user: user}
  end

  describe "GET /auth/passkeys/sign-in" do
    test "renders the ceremony and stores an authentication challenge", %{conn: conn} do
      conn = get(conn, "/auth/passkeys/sign-in")
      html = html_response(conn, 200)

      assert html =~ "data-passkeys"
      assert html =~ "data-mode=\"sign-in\""
      assert html =~ "Use security key or passkey"
      assert html =~ "Use a phone"
      assert html =~ "/assets/js/passkeys.js"

      challenge = H.challenge(conn)
      assert challenge["type"] == "authentication"
      refute Map.has_key?(challenge, "user_id")
    end

    test "is 404 when passkeys are disabled", %{conn: conn} do
      with_webauthn_config(enabled: false)

      conn = get(conn, "/auth/passkeys/sign-in")

      assert html_response(conn, 404) =~ "Page not found"
    end
  end

  describe "POST /auth/passkeys/sign-in" do
    test "signs the user in, renews the session, and records use", %{conn: conn, user: user} do
      fake = FakeAuthenticator.new()
      credential = register!(user, fake)

      {conn, challenge} = authentication_session(conn)
      assertion = FakeAuthenticator.assert(fake, challenge, sign_count: 1)

      result =
        conn
        |> H.json_post("/auth/passkeys/sign-in", H.assertion_payload(assertion))

      assert json_response(result, 200) == %{"redirect_to" => "/"}
      assert get_session(result, Passkeys.session_key()) == nil

      assert is_binary(get_session(result, :user_session_token))
      assert Cadence.Server.Repo.get_by(Cadence.Server.Accounts.UserSession, user_id: user.id)

      {:ok, used} = Ash.get(WebAuthnCredential, credential.id, domain: Accounts)
      assert used.sign_count == 1
      assert %DateTime{} = used.last_used_at

      # The new session cookie signs subsequent page requests in, and the
      # one-shot flash is waiting for the destination page.
      portfolio = html_response(get(result, "/"), 200)
      assert portfolio =~ to_string(user.email)
      assert portfolio =~ "Signed in with a security key."
    end

    test "honours a validated local return path", %{conn: conn, user: user} do
      fake = FakeAuthenticator.new()
      register!(user, fake)

      {conn, challenge} = authentication_session(conn)
      assertion = FakeAuthenticator.assert(fake, challenge, sign_count: 1)

      result =
        conn
        |> H.json_post(
          "/auth/passkeys/sign-in",
          H.assertion_payload(assertion, "/p/example")
        )

      assert json_response(result, 200) == %{"redirect_to" => "/p/example"}
    end

    test "rejects an open-redirect return path", %{conn: conn, user: user} do
      fake = FakeAuthenticator.new()
      register!(user, fake)

      {conn, challenge} = authentication_session(conn)
      assertion = FakeAuthenticator.assert(fake, challenge, sign_count: 1)

      result =
        conn
        |> H.json_post(
          "/auth/passkeys/sign-in",
          H.assertion_payload(assertion, "//evil.example")
        )

      assert json_response(result, 200) == %{"redirect_to" => "/"}
    end

    test "fails generically for an unknown credential", %{conn: conn} do
      unknown = FakeAuthenticator.new()
      {conn, challenge} = authentication_session(conn)
      assertion = FakeAuthenticator.assert(unknown, challenge)

      result =
        conn
        |> H.json_post("/auth/passkeys/sign-in", H.assertion_payload(assertion))

      assert json_response(result, 422) == %{"error" => @generic}
    end

    test "fails generically for a tampered signature", %{conn: conn, user: user} do
      fake = FakeAuthenticator.new()
      register!(user, fake)

      {conn, challenge} = authentication_session(conn)
      assertion = FakeAuthenticator.assert(fake, challenge, tamper_signature: true)

      result =
        conn
        |> H.json_post("/auth/passkeys/sign-in", H.assertion_payload(assertion))

      assert json_response(result, 422) == %{"error" => @generic}
    end

    test "fails generically for a missing or expired challenge", %{conn: conn, user: user} do
      fake = FakeAuthenticator.new()
      register!(user, fake)

      {:ok, %{challenge: challenge}} = Passkeys.authentication_challenge()
      assertion = FakeAuthenticator.assert(fake, challenge)

      missing =
        conn
        |> H.json_post("/auth/passkeys/sign-in", H.assertion_payload(assertion))

      assert json_response(missing, 422) == %{"error" => @generic}

      expired = Map.put(challenge, "issued_at", System.system_time(:second) - 121)
      expired_assertion = FakeAuthenticator.assert(fake, expired)

      expired_conn =
        conn
        |> init_test_session(%{Passkeys.session_key() => expired})
        |> H.json_post("/auth/passkeys/sign-in", H.assertion_payload(expired_assertion))

      assert json_response(expired_conn, 422) == %{"error" => @generic}
    end

    test "fails generically on replay against a fresh challenge", %{conn: conn, user: user} do
      fake = FakeAuthenticator.new()
      register!(user, fake)

      {:ok, %{challenge: challenge_a}} = Passkeys.authentication_challenge()
      assertion = FakeAuthenticator.assert(fake, challenge_a, sign_count: 1)

      {:ok, %{challenge: challenge_b}} = Passkeys.authentication_challenge()

      result =
        conn
        |> init_test_session(%{Passkeys.session_key() => challenge_b})
        |> H.json_post("/auth/passkeys/sign-in", H.assertion_payload(assertion))

      assert json_response(result, 422) == %{"error" => @generic}
    end

    test "fails generically when user verification is missing", %{conn: conn, user: user} do
      fake = FakeAuthenticator.new()
      register!(user, fake)

      {conn, challenge} = authentication_session(conn)
      assertion = FakeAuthenticator.assert(fake, challenge, flags: 0x01)

      result =
        conn
        |> H.json_post("/auth/passkeys/sign-in", H.assertion_payload(assertion))

      assert json_response(result, 422) == %{"error" => @generic}
    end

    test "does not reveal whether the account exists", %{conn: conn, user: user} do
      fake = FakeAuthenticator.new()
      register!(user, fake)

      {conn, challenge} = authentication_session(conn)
      assertion = FakeAuthenticator.assert(fake, challenge, tamper_signature: true)

      result =
        conn
        |> H.json_post("/auth/passkeys/sign-in", H.assertion_payload(assertion))

      body = json_response(result, 422)
      assert body == %{"error" => @generic}
      refute inspect(body) =~ to_string(user.email)
      refute inspect(body) =~ "unknown"
      refute inspect(body) =~ "credential"
      refute inspect(body) =~ "signature"
    end

    test "requires the x-csrf-token header", %{conn: conn, user: user} do
      fake = FakeAuthenticator.new()
      register!(user, fake)

      {:ok, %{challenge: challenge}} = Passkeys.authentication_challenge()
      assertion = FakeAuthenticator.assert(fake, challenge, sign_count: 1)

      assert {403, _headers, _body} =
               assert_error_sent(403, fn ->
                 conn
                 |> init_test_session(%{Passkeys.session_key() => challenge})
                 |> H.enable_csrf()
                 |> H.json_post("/auth/passkeys/sign-in", H.assertion_payload(assertion))
               end)
    end

    test "accepts the x-csrf-token header the browser sends", %{conn: conn, user: user} do
      fake = FakeAuthenticator.new()
      register!(user, fake)

      {:ok, %{challenge: challenge}} = Passkeys.authentication_challenge()
      assertion = FakeAuthenticator.assert(fake, challenge, sign_count: 1)
      {conn, token} = H.csrf_session(conn)

      result =
        conn
        |> put_session(Passkeys.session_key(), challenge)
        |> H.enable_csrf()
        |> H.json_post(
          "/auth/passkeys/sign-in",
          H.assertion_payload(assertion),
          csrf: token
        )

      assert json_response(result, 200) == %{"redirect_to" => "/"}
    end

    test "is 404 when passkeys are disabled", %{conn: conn} do
      with_webauthn_config(enabled: false)

      result =
        conn
        |> H.json_post("/auth/passkeys/sign-in", %{"rawId" => "bogus"})

      assert json_response(result, 404) == %{"error" => "not_found"}
    end

    test "is rate limited per client IP", %{conn: conn} do
      with_webauthn_config(rate_limit: 1, rate_scale: 60_000)

      first =
        conn
        |> H.json_post("/auth/passkeys/sign-in", %{"rawId" => "bogus"})

      assert first.status == 422

      second =
        conn
        |> H.json_post("/auth/passkeys/sign-in", %{"rawId" => "bogus"})

      assert second.status == 429
      assert [retry_after] = get_resp_header(second, "retry-after")
      assert String.to_integer(retry_after) >= 1
      assert json_response(second, 429) == %{"error" => "rate_limited"}
    end
  end

  # Mints a challenge and seeds it into a `build_conn` session without a GET,
  # so the POST exercises the same path a browser uses.
  defp authentication_session(conn) do
    {:ok, %{challenge: challenge}} = Passkeys.authentication_challenge()
    {init_test_session(conn, %{Passkeys.session_key() => challenge}), challenge}
  end

  defp register!(user, fake) do
    {:ok, %{challenge: challenge}} = Passkeys.registration_challenge(user)
    response = FakeAuthenticator.attest(fake, challenge)
    {:ok, verification} = Passkeys.verify_registration(user, challenge, response)
    {:ok, credential} = Passkeys.create_credential(user, verification, %{label: "Test key"})
    credential
  end

  defp with_webauthn_config(overrides) do
    original = Application.get_env(:cadence_server, :webauthn)
    Application.put_env(:cadence_server, :webauthn, Keyword.merge(original, overrides))
    on_exit(fn -> Application.put_env(:cadence_server, :webauthn, original) end)
    :ok
  end
end
