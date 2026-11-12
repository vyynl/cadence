defmodule Cadence.Server.PasskeysTest do
  use ExUnit.Case, async: false

  alias Cadence.Server.Accounts.User
  alias Cadence.Server.FakeAuthenticator
  alias Cadence.Server.Passkeys

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Cadence.Server.Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    suffix = System.unique_integer([:positive])

    {:ok,
     user: Ash.Seed.seed!(User, %{email: "passkeys-#{suffix}@example.com", name: "Key Owner"}),
     other_user: Ash.Seed.seed!(User, %{email: "other-#{suffix}@example.com"})}
  end

  describe "registration challenge" do
    test "returns browser options and a session challenge", %{user: user} do
      assert {:ok, %{public_key: options, challenge: challenge}} =
               Passkeys.registration_challenge(user)

      assert options["rp"] == %{"id" => "localhost", "name" => "Cadence Test"}
      assert options["attestation"] == "none"
      assert options["timeout"] == 120_000
      assert options["excludeCredentials"] == []

      assert options["authenticatorSelection"] == %{
               "residentKey" => "required",
               "requireResidentKey" => true,
               "userVerification" => "required"
             }

      assert Enum.map(options["pubKeyCredParams"], & &1["alg"]) == [-7, -257]

      assert Base.url_decode64!(options["challenge"], padding: false) ==
               Base.decode64!(challenge["bytes"])

      assert byte_size(Base.url_decode64!(options["user"]["id"], padding: false)) == 32
      assert options["user"]["name"] == to_string(user.email)
      assert challenge["type"] == "attestation"
      assert challenge["origin"] == "http://localhost:4000"
      assert challenge["rp_id"] == "localhost"
      assert challenge["user_id"] == user.id
      assert is_integer(challenge["issued_at"])
    end

    test "derives a stable opaque user handle", %{user: user} do
      assert {:ok, %{public_key: first}} = Passkeys.registration_challenge(user)
      assert {:ok, %{public_key: second}} = Passkeys.registration_challenge(user)
      assert first["user"]["id"] == second["user"]["id"]
    end

    test "excludes already registered credentials", %{user: user} do
      {credential, _challenge, _response} = register(user, FakeAuthenticator.new())

      assert {:ok, %{public_key: options}} = Passkeys.registration_challenge(user)
      [descriptor] = options["excludeCredentials"]

      assert descriptor["type"] == "public-key"
      assert Base.url_decode64!(descriptor["id"], padding: false) == credential.credential_id
      assert descriptor["transports"] == ["usb"]
    end

    test "is disabled when CAD_WEBAUTHN_ENABLED=false", %{user: user} do
      with_webauthn_config(enabled: false)
      assert {:error, :disabled} = Passkeys.registration_challenge(user)
      assert {:error, :disabled} = Passkeys.authentication_challenge()
    end
  end

  describe "registration verification" do
    test "accepts a valid attestation and stores one row", %{user: user} do
      fake = FakeAuthenticator.new()
      {:ok, %{challenge: challenge}} = Passkeys.registration_challenge(user)
      response = FakeAuthenticator.attest(fake, challenge)

      assert {:ok, verification} =
               Passkeys.verify_registration(user, challenge, response)

      assert verification.credential_id == fake.credential_id
      assert verification.public_key == fake.cose_key
      assert verification.sign_count == 0
      assert verification.aaguid == fake.aaguid
      assert verification.attestation_type == "none"
      assert verification.transports == ["usb"]

      assert {:ok, credential} =
               Passkeys.create_credential(user, verification, %{label: "Desk key"})

      assert credential.label == "Desk key"
      assert {:ok, [listed]} = Passkeys.list(user)
      assert listed.id == credential.id
    end

    test "rejects an expired challenge", %{user: user} do
      fake = FakeAuthenticator.new()
      {:ok, %{challenge: challenge}} = Passkeys.registration_challenge(user)

      expired =
        Map.put(challenge, "issued_at", System.system_time(:second) - 121)

      response = FakeAuthenticator.attest(fake, expired)

      assert {:error, :expired} = Passkeys.verify_registration(user, expired, response)
    end

    test "rejects a challenge of the wrong ceremony type", %{user: user} do
      fake = FakeAuthenticator.new()
      {:ok, %{challenge: challenge}} = Passkeys.authentication_challenge()
      response = FakeAuthenticator.attest(fake, challenge)

      assert {:error, :wrong_type} = Passkeys.verify_registration(user, challenge, response)
    end

    test "rejects a challenge minted for another user", %{user: user, other_user: other_user} do
      fake = FakeAuthenticator.new()
      {:ok, %{challenge: challenge}} = Passkeys.registration_challenge(user)
      response = FakeAuthenticator.attest(fake, challenge)

      assert {:error, :challenge_user_mismatch} =
               Passkeys.verify_registration(other_user, challenge, response)
    end

    test "rejects a wrong origin or RP ID", %{user: user} do
      fake = FakeAuthenticator.new()
      {:ok, %{challenge: challenge}} = Passkeys.registration_challenge(user)

      wrong_origin = FakeAuthenticator.attest(fake, challenge, origin: "https://evil.example")
      assert {:error, :wrong_origin} = Passkeys.verify_registration(user, challenge, wrong_origin)

      wrong_rp = FakeAuthenticator.attest(fake, challenge, rp_id: "evil.example")
      assert {:error, :wrong_rp_id} = Passkeys.verify_registration(user, challenge, wrong_rp)
    end

    test "rejects a response whose UV flag is missing", %{user: user} do
      fake = FakeAuthenticator.new()
      {:ok, %{challenge: challenge}} = Passkeys.registration_challenge(user)
      response = FakeAuthenticator.attest(fake, challenge, flags: 0x41)

      assert {:error, :user_verification_failed} =
               Passkeys.verify_registration(user, challenge, response)
    end

    test "rejects a malformed response", %{user: user} do
      {:ok, %{challenge: challenge}} = Passkeys.registration_challenge(user)

      assert {:error, :invalid_attestation} =
               Passkeys.verify_registration(user, challenge, %{client_data_json: "{}"})
    end

    test "maps a duplicate credential id without creating a second row", %{user: user} do
      fake = FakeAuthenticator.new()
      {_credential, _challenge, _response} = register(user, fake)

      {:ok, %{challenge: challenge}} = Passkeys.registration_challenge(user)
      response = FakeAuthenticator.attest(fake, challenge)
      {:ok, verification} = Passkeys.verify_registration(user, challenge, response)

      assert {:error, :duplicate_credential} = Passkeys.create_credential(user, verification)
      assert {:ok, [_one]} = Passkeys.list(user)
    end

    test "enforces the per-user credential cap", %{user: user} do
      with_webauthn_config(max_credentials: 1)

      {_credential, _challenge, _response} = register(user, FakeAuthenticator.new())

      fake = FakeAuthenticator.new(credential_id: :crypto.strong_rand_bytes(32))
      {:ok, %{challenge: challenge}} = Passkeys.registration_challenge(user)
      response = FakeAuthenticator.attest(fake, challenge)
      {:ok, verification} = Passkeys.verify_registration(user, challenge, response)

      assert {:error, :max_credentials} = Passkeys.create_credential(user, verification)
    end
  end

  describe "authentication verification" do
    test "accepts a valid assertion and advances the counter", %{user: user} do
      fake = FakeAuthenticator.new()
      {credential, _challenge, _response} = register(user, fake)

      assert {:ok, %{public_key: options, challenge: challenge}} =
               Passkeys.authentication_challenge()

      assert options["allowCredentials"] == []
      assert options["rpId"] == "localhost"
      assert options["userVerification"] == "required"

      response = FakeAuthenticator.assert(fake, challenge, sign_count: 1)

      assert {:ok, result} = Passkeys.verify_authentication(challenge, response)
      assert result.credential.id == credential.id
      assert result.user_id == user.id
      assert result.sign_count == 1

      assert {:ok, used} = Passkeys.record_use(user, credential.credential_id, result.sign_count)
      assert used.sign_count == 1
      assert %DateTime{} = used.last_used_at
    end

    test "rejects an assertion replayed against a fresh challenge", %{user: user} do
      fake = FakeAuthenticator.new()
      {_credential, _challenge, _response} = register(user, fake)

      {:ok, %{challenge: challenge_a}} = Passkeys.authentication_challenge()
      assertion = FakeAuthenticator.assert(fake, challenge_a, sign_count: 1)

      {:ok, %{challenge: challenge_b}} = Passkeys.authentication_challenge()

      assert {:error, :invalid_assertion} = Passkeys.verify_authentication(challenge_b, assertion)
    end

    test "rejects an expired authentication challenge", %{user: user} do
      fake = FakeAuthenticator.new()
      {_credential, _challenge, _response} = register(user, fake)

      {:ok, %{challenge: challenge}} = Passkeys.authentication_challenge()

      expired = Map.put(challenge, "issued_at", System.system_time(:second) - 121)
      assertion = FakeAuthenticator.assert(fake, expired, sign_count: 1)

      assert {:error, :expired} = Passkeys.verify_authentication(expired, assertion)
    end

    test "rejects a registration challenge at sign-in", %{user: user} do
      fake = FakeAuthenticator.new()
      {:ok, %{challenge: challenge}} = Passkeys.registration_challenge(user)
      assertion = FakeAuthenticator.assert(fake, challenge)

      assert {:error, :wrong_type} = Passkeys.verify_authentication(challenge, assertion)
    end

    test "rejects an unknown credential", %{user: user} do
      fake = FakeAuthenticator.new()
      {_credential, _challenge, _response} = register(user, fake)

      {:ok, %{challenge: challenge}} = Passkeys.authentication_challenge()

      assertion =
        FakeAuthenticator.assert(fake, challenge, credential_id: :crypto.strong_rand_bytes(32))

      assert {:error, :unknown_credential} = Passkeys.verify_authentication(challenge, assertion)
    end

    test "rejects a tampered signature", %{user: user} do
      fake = FakeAuthenticator.new()
      {_credential, _challenge, _response} = register(user, fake)

      {:ok, %{challenge: challenge}} = Passkeys.authentication_challenge()

      assertion = FakeAuthenticator.assert(fake, challenge, tamper_signature: true)

      assert {:error, :invalid_assertion} = Passkeys.verify_authentication(challenge, assertion)
    end

    test "rejects an assertion without UV", %{user: user} do
      fake = FakeAuthenticator.new()
      {_credential, _challenge, _response} = register(user, fake)

      {:ok, %{challenge: challenge}} = Passkeys.authentication_challenge()
      assertion = FakeAuthenticator.assert(fake, challenge, flags: 0x01)

      assert {:error, :user_verification_failed} =
               Passkeys.verify_authentication(challenge, assertion)
    end
  end

  describe "sign counter rules" do
    test "rejects a counter that does not advance when both are non-zero", %{user: user} do
      fake = FakeAuthenticator.new()
      {credential, _challenge, _response} = register(user, fake, %{}, sign_count: 5)

      {:ok, %{challenge: challenge}} = Passkeys.authentication_challenge()
      assertion = FakeAuthenticator.assert(fake, challenge, sign_count: 5)

      assert {:error, :sign_count_regression} =
               Passkeys.verify_authentication(challenge, assertion)

      assert {:error, :sign_count_regression} =
               Passkeys.record_use(user, credential.credential_id, 5)
    end

    test "accepts a zero counter and never lowers the stored value", %{user: user} do
      fake = FakeAuthenticator.new()
      {credential, _challenge, _response} = register(user, fake, %{}, sign_count: 5)

      {:ok, %{challenge: challenge}} = Passkeys.authentication_challenge()
      assertion = FakeAuthenticator.assert(fake, challenge, sign_count: 0)

      assert {:ok, result} = Passkeys.verify_authentication(challenge, assertion)
      assert result.sign_count == 0

      assert {:ok, used} = Passkeys.record_use(user, credential.credential_id, 0)
      assert used.sign_count == 5
    end

    test "accepts 0/0 and N/N+1", %{user: user} do
      fake = FakeAuthenticator.new()
      {credential, _challenge, _response} = register(user, fake, %{}, sign_count: 0)

      assert {:ok, used} = Passkeys.record_use(user, credential.credential_id, 0)
      assert used.sign_count == 0

      assert {:ok, used} = Passkeys.record_use(user, credential.credential_id, 1)
      assert used.sign_count == 1

      assert {:ok, used} = Passkeys.record_use(user, credential.credential_id, 2)
      assert used.sign_count == 2
    end
  end

  describe "credential management" do
    test "lists, renames, and deletes only the caller's credentials", %{
      user: user,
      other_user: other_user
    } do
      {mine, _challenge, _response} = register(user, FakeAuthenticator.new())
      {theirs, _challenge, _response} = register(other_user, FakeAuthenticator.new())

      assert {:ok, [listed]} = Passkeys.list(user)
      assert listed.id == mine.id

      assert {:ok, renamed} = Passkeys.rename(user, mine.credential_id, "Laptop")
      assert renamed.label == "Laptop"

      assert {:error, :not_found} = Passkeys.rename(user, theirs.credential_id, "Stolen")
      assert {:error, :not_found} = Passkeys.delete(user, theirs.credential_id)

      assert :ok = Passkeys.delete(user, mine.credential_id)
      assert {:ok, []} = Passkeys.list(user)
      assert {:ok, [_theirs_still_there]} = Passkeys.list(other_user)
    end

    test "rejects an invalid label", %{user: user} do
      {credential, _challenge, _response} = register(user, FakeAuthenticator.new())

      assert {:error, :invalid_label} =
               Passkeys.rename(user, credential.credential_id, "\u202Eevil")
    end
  end

  describe "challenge validation helpers" do
    test "rejects malformed or undecodable challenges", %{user: user} do
      assert {:error, :invalid_challenge} = Passkeys.consume_challenge(%{})

      {:ok, %{challenge: challenge}} = Passkeys.registration_challenge(user)

      assert {:error, :invalid_challenge} =
               Passkeys.consume_challenge(Map.put(challenge, "bytes", "!!!"))
    end

    test "binds the challenge to the configured origin and RP ID", %{user: user} do
      fake = FakeAuthenticator.new()
      {:ok, %{challenge: challenge}} = Passkeys.registration_challenge(user)
      response = FakeAuthenticator.attest(fake, challenge)

      wrong_origin = Map.put(challenge, "origin", "https://evil.example")
      assert {:error, :wrong_origin} = Passkeys.verify_registration(user, wrong_origin, response)

      wrong_rp_id = Map.put(challenge, "rp_id", "evil.example")
      assert {:error, :wrong_rp_id} = Passkeys.verify_registration(user, wrong_rp_id, response)
    end

    test "returns a Wax challenge with the expected binding", %{user: user} do
      {:ok, %{challenge: challenge}} = Passkeys.registration_challenge(user)

      assert {:ok, %Wax.Challenge{} = wax_challenge} =
               Passkeys.consume_challenge(challenge,
                 type: :attestation,
                 user_id: user.id
               )

      assert wax_challenge.type == :attestation
      assert wax_challenge.rp_id == "localhost"
      assert wax_challenge.origin == "http://localhost:4000"
      assert wax_challenge.user_verification == "required"
    end
  end

  # Registers a credential, optionally seeding the fake authenticator's counter.
  defp register(user, fake, attrs \\ %{}, opts \\ []) do
    sign_count = Keyword.get(opts, :sign_count, fake.sign_count)

    {:ok, %{challenge: challenge}} = Passkeys.registration_challenge(user)
    response = FakeAuthenticator.attest(fake, challenge, sign_count: sign_count)
    {:ok, verification} = Passkeys.verify_registration(user, challenge, response)
    {:ok, credential} = Passkeys.create_credential(user, verification, attrs)
    {credential, challenge, response}
  end

  defp with_webauthn_config(overrides) do
    original = Application.get_env(:cadence_server, :webauthn)
    Application.put_env(:cadence_server, :webauthn, Keyword.merge(original, overrides))
    on_exit(fn -> Application.put_env(:cadence_server, :webauthn, original) end)
    :ok
  end
end
