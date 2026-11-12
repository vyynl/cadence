defmodule Cadence.ServerWeb.AccountSecurityControllerTest do
  @moduledoc """
  Account security registration and management (plan §7.5, §7.7).
  """

  use Cadence.ServerWeb.ConnCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Cadence.Server.Accounts.User
  alias Cadence.Server.FakeAuthenticator
  alias Cadence.Server.Passkeys
  alias Cadence.ServerWeb.PasskeyTestHelpers, as: H

  setup do
    suffix = System.unique_integer([:positive])

    {:ok,
     user:
       Ash.Seed.seed!(User, %{
         email: "security-#{suffix}@example.com",
         name: "Security Owner"
       }),
     other_user:
       Ash.Seed.seed!(User, %{email: "security-other-#{suffix}@example.com", name: "Other"})}
  end

  describe "account security page" do
    test "an anonymous request redirects to sign-in", %{conn: conn} do
      conn = get(conn, "/account/security")

      assert redirected_to(conn) == "/sign-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Sign in"
    end

    test "a signed-in user sees their keys", %{conn: conn, user: user} do
      register!(user, FakeAuthenticator.new(), "Desk YubiKey")

      html =
        conn
        |> H.signed_conn(user)
        |> get("/account/security")
        |> html_response(200)

      assert html =~ "Security keys and passkeys"
      assert html =~ "Desk YubiKey"
      assert html =~ "Security key (USB/NFC)"
      assert html =~ "Add a security key or passkey"
      assert html =~ "OAuth is the recovery path"
    end

    test "the only-key warning is shown for a single credential", %{conn: conn, user: user} do
      register!(user, FakeAuthenticator.new(), "Only key")

      html =
        conn
        |> H.signed_conn(user)
        |> get("/account/security")
        |> html_response(200)

      assert html =~ "This is your only security key"
    end

    test "the add button disappears at the per-user cap", %{conn: conn, user: user} do
      with_webauthn_config(max_credentials: 1)
      register!(user, FakeAuthenticator.new(), "Capped")

      html =
        conn
        |> H.signed_conn(user)
        |> get("/account/security")
        |> html_response(200)

      refute html =~ "Add a security key or passkey"
      assert html =~ "You have reached the limit of 1 keys"
    end

    test "passkeys are 404 when disabled", %{conn: conn, user: user} do
      with_webauthn_config(enabled: false)

      conn = conn |> H.signed_conn(user) |> get("/account/security")

      assert html_response(conn, 404) =~ "Page not found"
    end
  end

  describe "registration" do
    test "GET mints a challenge and renders the browser options", %{conn: conn, user: user} do
      conn = conn |> H.signed_conn(user) |> get("/account/security/keys/new")
      html = html_response(conn, 200)

      assert html =~ "data-passkeys"
      assert html =~ "data-mode=\"register\""
      assert html =~ "/assets/js/passkeys.js"

      challenge = H.challenge(conn)
      assert challenge["type"] == "attestation"
      assert challenge["user_id"] == user.id
    end

    test "GET is authenticated", %{conn: conn} do
      conn = get(conn, "/account/security/keys/new")

      assert redirected_to(conn) == "/sign-in"
    end

    test "POST stores a credential and consumes the challenge", %{conn: conn, user: user} do
      fake = FakeAuthenticator.new()
      {:ok, %{challenge: challenge}} = Passkeys.registration_challenge(user)
      response = FakeAuthenticator.attest(fake, challenge)
      payload = H.registration_payload(response, "Desk key")

      conn =
        conn
        |> H.signed_conn(user)
        |> put_session(Passkeys.session_key(), challenge)
        |> H.json_post("/account/security/keys", payload)

      assert json_response(conn, 200) == %{"redirect_to" => "/account/security"}
      assert get_session(conn, Passkeys.session_key()) == nil
      assert {:ok, [credential]} = Passkeys.list(user)
      assert credential.label == "Desk key"
      assert credential.transports == ["usb"]

      follow_up = get(conn, "/account/security")
      assert html_response(follow_up, 200) =~ "Security key added: Desk key."
    end

    test "POST maps a duplicate credential to a clean message", %{conn: conn, user: user} do
      fake = FakeAuthenticator.new()
      register!(user, fake, "First")

      {:ok, %{challenge: challenge}} = Passkeys.registration_challenge(user)
      response = FakeAuthenticator.attest(fake, challenge)
      payload = H.registration_payload(response, "Duplicate")

      conn =
        conn
        |> H.signed_conn(user)
        |> put_session(Passkeys.session_key(), challenge)
        |> H.json_post("/account/security/keys", payload)

      assert %{"error" => message} = json_response(conn, 422)
      assert message =~ "already registered"
      assert {:ok, [_one]} = Passkeys.list(user)
    end

    test "POST enforces the per-user cap", %{conn: conn, user: user} do
      with_webauthn_config(max_credentials: 1)
      register!(user, FakeAuthenticator.new(), "First")

      fake = FakeAuthenticator.new()
      {:ok, %{challenge: challenge}} = Passkeys.registration_challenge(user)
      response = FakeAuthenticator.attest(fake, challenge)
      payload = H.registration_payload(response, "Second")

      conn =
        conn
        |> H.signed_conn(user)
        |> put_session(Passkeys.session_key(), challenge)
        |> H.json_post("/account/security/keys", payload)

      assert %{"error" => message} = json_response(conn, 422)
      assert message =~ "maximum number of security keys"
      assert {:ok, [_one]} = Passkeys.list(user)
    end

    test "POST rejects a missing or expired challenge", %{conn: conn, user: user} do
      fake = FakeAuthenticator.new()
      {:ok, %{challenge: challenge}} = Passkeys.registration_challenge(user)
      response = FakeAuthenticator.attest(fake, challenge)
      payload = H.registration_payload(response, "Expired")

      # Missing: the session has no challenge.
      missing =
        conn
        |> H.signed_conn(user)
        |> H.json_post("/account/security/keys", payload)

      assert %{"error" => message} = json_response(missing, 422)
      assert message =~ "expired"

      expired =
        Map.put(challenge, "issued_at", System.system_time(:second) - 121)

      expired_response = FakeAuthenticator.attest(fake, expired)
      expired_payload = H.registration_payload(expired_response, "Expired")

      expired_conn =
        conn
        |> H.signed_conn(user)
        |> put_session(Passkeys.session_key(), expired)
        |> H.json_post("/account/security/keys", expired_payload)

      assert %{"error" => expired_message} = json_response(expired_conn, 422)
      assert expired_message =~ "expired"

      assert {:ok, []} = Passkeys.list(user)
    end

    test "POST rejects an invalid label without storing a key", %{conn: conn, user: user} do
      fake = FakeAuthenticator.new()
      {:ok, %{challenge: challenge}} = Passkeys.registration_challenge(user)
      response = FakeAuthenticator.attest(fake, challenge)
      payload = H.registration_payload(response, "   ")

      conn =
        conn
        |> H.signed_conn(user)
        |> put_session(Passkeys.session_key(), challenge)
        |> H.json_post("/account/security/keys", payload)

      assert %{"error" => message} = json_response(conn, 422)
      assert message =~ "between 1 and 60"
      assert {:ok, []} = Passkeys.list(user)
    end

    test "POST without a CSRF token is rejected", %{conn: conn, user: user} do
      fake = FakeAuthenticator.new()
      {:ok, %{challenge: challenge}} = Passkeys.registration_challenge(user)
      response = FakeAuthenticator.attest(fake, challenge)
      payload = H.registration_payload(response, "No CSRF")

      assert {403, _headers, _body} =
               assert_error_sent(403, fn ->
                 conn
                 |> H.signed_conn(user)
                 |> put_session(Passkeys.session_key(), challenge)
                 |> H.enable_csrf()
                 |> H.json_post("/account/security/keys", payload)
               end)

      assert {:ok, []} = Passkeys.list(user)
    end

    test "POST accepts the x-csrf-token header the browser sends", %{conn: conn, user: user} do
      fake = FakeAuthenticator.new()
      {:ok, %{challenge: challenge}} = Passkeys.registration_challenge(user)
      response = FakeAuthenticator.attest(fake, challenge)
      payload = H.registration_payload(response, "CSRF ok")

      {conn, token} = H.csrf_session(conn)

      conn =
        conn
        |> H.signed_conn(user)
        |> put_session(Passkeys.session_key(), challenge)
        |> H.enable_csrf()
        |> H.json_post("/account/security/keys", payload, csrf: token)

      assert json_response(conn, 200) == %{"redirect_to" => "/account/security"}
      assert {:ok, [_one]} = Passkeys.list(user)
    end

    test "an anonymous POST is rejected without touching the session", %{conn: conn, user: user} do
      fake = FakeAuthenticator.new()
      {:ok, %{challenge: challenge}} = Passkeys.registration_challenge(user)
      response = FakeAuthenticator.attest(fake, challenge)
      payload = H.registration_payload(response, "Anon")

      conn =
        conn
        |> init_test_session(%{Passkeys.session_key() => challenge})
        |> H.json_post("/account/security/keys", payload)

      assert json_response(conn, 401) == %{"error" => "Sign in to manage security keys."}
      assert get_session(conn, Passkeys.session_key()) == challenge
      assert {:ok, []} = Passkeys.list(user)
    end
  end

  describe "management" do
    test "renames a key addressed by row id", %{conn: conn, user: user} do
      credential = register!(user, FakeAuthenticator.new(), "Old name")

      conn =
        conn
        |> H.signed_conn(user)
        |> post("/account/security/keys/#{credential.id}/rename", %{"label" => "New name"})

      assert redirected_to(conn) == "/account/security"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "New name"

      assert {:ok, [updated]} = Passkeys.list(user)
      assert updated.label == "New name"
    end

    test "rejects an invalid rename label", %{conn: conn, user: user} do
      credential = register!(user, FakeAuthenticator.new(), "Kept")

      conn =
        conn
        |> H.signed_conn(user)
        |> post("/account/security/keys/#{credential.id}/rename", %{"label" => "   "})

      assert redirected_to(conn) == "/account/security"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "between 1 and 60"
      assert {:ok, [updated]} = Passkeys.list(user)
      assert updated.label == "Kept"
    end

    test "removes a key after confirmation", %{conn: conn, user: user} do
      credential = register!(user, FakeAuthenticator.new(), "Remove me")

      conn =
        conn
        |> H.signed_conn(user)
        |> post("/account/security/keys/#{credential.id}/delete")

      assert redirected_to(conn) == "/account/security"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "removed"
      assert {:ok, []} = Passkeys.list(user)
    end

    test "cannot remove or rename another user's key", %{
      conn: conn,
      user: user,
      other_user: other_user
    } do
      mine = register!(user, FakeAuthenticator.new(), "Mine")
      theirs = register!(other_user, FakeAuthenticator.new(), "Theirs")

      deleted =
        conn
        |> H.signed_conn(user)
        |> post("/account/security/keys/#{theirs.id}/delete")

      assert Phoenix.Flash.get(deleted.assigns.flash, :error) =~ "could not be found"
      assert {:ok, [_theirs]} = Passkeys.list(other_user)

      renamed =
        conn
        |> H.signed_conn(user)
        |> post("/account/security/keys/#{theirs.id}/rename", %{"label" => "Stolen"})

      assert Phoenix.Flash.get(renamed.assigns.flash, :error) =~ "could not be found"
      assert {:ok, [still_theirs]} = Passkeys.list(other_user)
      assert still_theirs.label == "Theirs"
      assert {:ok, [_mine]} = Passkeys.list(user)
      assert mine.label == "Mine"
    end

    test "a malformed row id is treated as not found", %{conn: conn, user: user} do
      conn =
        conn
        |> H.signed_conn(user)
        |> post("/account/security/keys/not-a-uuid/delete")

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "could not be found"
    end

    test "the last key is removable because OAuth is the recovery path", %{
      conn: conn,
      user: user
    } do
      credential = register!(user, FakeAuthenticator.new(), "Last key")

      conn =
        conn
        |> H.signed_conn(user)
        |> post("/account/security/keys/#{credential.id}/delete")

      assert redirected_to(conn) == "/account/security"
      assert {:ok, []} = Passkeys.list(user)
    end
  end

  defp register!(user, fake, label, opts \\ []) do
    sign_count = Keyword.get(opts, :sign_count, fake.sign_count)

    {:ok, %{challenge: challenge}} = Passkeys.registration_challenge(user)
    response = FakeAuthenticator.attest(fake, challenge, sign_count: sign_count)
    {:ok, verification} = Passkeys.verify_registration(user, challenge, response)
    {:ok, credential} = Passkeys.create_credential(user, verification, %{label: label})
    credential
  end

  defp with_webauthn_config(overrides) do
    original = Application.get_env(:cadence_server, :webauthn)
    Application.put_env(:cadence_server, :webauthn, Keyword.merge(original, overrides))
    on_exit(fn -> Application.put_env(:cadence_server, :webauthn, original) end)
    :ok
  end
end
