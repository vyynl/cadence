defmodule Cadence.Server.Accounts.WebAuthnCredentialTest do
  use ExUnit.Case, async: false

  alias Cadence.Server.Accounts
  alias Cadence.Server.Accounts.{User, WebAuthnCredential}
  alias Cadence.Server.FakeAuthenticator

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Cadence.Server.Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    {:ok,
     user:
       Ash.Seed.seed!(User, %{email: "keys-#{System.unique_integer([:positive])}@example.com"})}
  end

  test "creates a credential with a COSE public key", %{user: user} do
    fake = FakeAuthenticator.new()

    assert {:ok, credential} =
             Ash.create(WebAuthnCredential, attrs(user, fake), action: :create, domain: Accounts)

    assert credential.credential_id == fake.credential_id
    assert credential.public_key == fake.cose_key
    assert credential.sign_count == 0
    assert credential.aaguid == fake.aaguid
    assert credential.attestation_type == "none"
    assert credential.transports == ["usb"]
    assert credential.label == "Desk key"

    loaded = Ash.get!(WebAuthnCredential, credential.id, domain: Accounts)
    assert loaded.public_key == fake.cose_key
  end

  test "enforces the unique credential id index", %{user: user} do
    fake = FakeAuthenticator.new()

    assert {:ok, _credential} =
             Ash.create(WebAuthnCredential, attrs(user, fake), action: :create, domain: Accounts)

    assert {:error, error} =
             Ash.create(WebAuthnCredential, attrs(user, fake), action: :create, domain: Accounts)

    assert Exception.message(error) =~ "already been taken"
    assert {:ok, credentials} = Ash.read(WebAuthnCredential, domain: Accounts)
    assert length(credentials) == 1
  end

  test "rejects a credential id outside 1..1023 bytes", %{user: user} do
    fake = FakeAuthenticator.new()

    assert {:error, _} =
             Ash.create(
               WebAuthnCredential,
               attrs(user, fake, %{credential_id: <<>>}),
               action: :create,
               domain: Accounts
             )

    assert {:error, _} =
             Ash.create(
               WebAuthnCredential,
               attrs(user, fake, %{credential_id: :binary.copy(<<1>>, 1024)}),
               action: :create,
               domain: Accounts
             )
  end

  test "validates the label length and rejects control/bidi characters", %{user: user} do
    fake = FakeAuthenticator.new()

    assert {:ok, _credential} =
             Ash.create(
               WebAuthnCredential,
               attrs(user, fake, %{label: String.duplicate("a", 60)}),
               action: :create,
               domain: Accounts
             )

    for bad_label <- [
          String.duplicate("a", 61),
          "desk\u0007",
          "\u202Eevil",
          ""
        ] do
      assert {:error, _} =
               Ash.create(
                 WebAuthnCredential,
                 attrs(user, fake, %{label: bad_label}),
                 action: :create,
                 domain: Accounts
               )
    end
  end

  test "validates transports, sign count, AAGUID, and attestation type", %{user: user} do
    fake = FakeAuthenticator.new()

    for overrides <- [
          %{transports: ["usb", "wifi"]},
          %{sign_count: -1},
          %{aaguid: :binary.copy(<<0>>, 15)},
          %{attestation_type: "direct"}
        ] do
      assert {:error, _} =
               Ash.create(
                 WebAuthnCredential,
                 attrs(user, fake, overrides),
                 action: :create,
                 domain: Accounts
               )
    end
  end

  test "keeps credential material out of public serialization" do
    for field <- [:credential_id, :public_key, :sign_count, :aaguid, :attestation_type] do
      attribute = Ash.Resource.Info.attribute(WebAuthnCredential, field)
      refute attribute.public?, "#{field} must not be public"
      assert attribute.sensitive?, "#{field} must be sensitive"
    end

    for field <- [:label, :transports, :last_used_at, :inserted_at, :updated_at] do
      assert Ash.Resource.Info.attribute(WebAuthnCredential, field).public?,
             "#{field} must be public"
    end
  end

  test "renames and records use", %{user: user} do
    fake = FakeAuthenticator.new()

    {:ok, credential} =
      Ash.create(WebAuthnCredential, attrs(user, fake), action: :create, domain: Accounts)

    assert {:ok, renamed} =
             credential
             |> Ash.Changeset.for_update(:rename, %{label: "YubiKey 5C — desk"})
             |> Ash.update(domain: Accounts)

    assert renamed.label == "YubiKey 5C — desk"

    used_at = DateTime.utc_now()

    assert {:ok, used} =
             renamed
             |> Ash.Changeset.for_update(:record_use, %{sign_count: 4, last_used_at: used_at})
             |> Ash.update(domain: Accounts)

    assert used.sign_count == 4
    assert used.last_used_at == used_at
  end

  test "User exposes a webauthn_credentials relationship", %{user: user} do
    fake = FakeAuthenticator.new()

    {:ok, credential} =
      Ash.create(WebAuthnCredential, attrs(user, fake), action: :create, domain: Accounts)

    loaded = Ash.load!(user, :webauthn_credentials, domain: Accounts)
    assert Enum.map(loaded.webauthn_credentials, & &1.id) == [credential.id]
  end

  defp attrs(user, fake, overrides \\ %{}) do
    Map.merge(
      %{
        user_id: user.id,
        credential_id: fake.credential_id,
        public_key: fake.cose_key,
        sign_count: 0,
        aaguid: fake.aaguid,
        attestation_type: "none",
        transports: ["usb"],
        label: "Desk key"
      },
      overrides
    )
  end
end
