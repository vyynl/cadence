defmodule Cadence.Server.Accounts.WebAuthnCredential do
  @moduledoc """
  A registered WebAuthn credential (security key or passkey), one row per
  credential (spec §7.4, plan §7.2).

  Authorization is owned by the caller: there is deliberately no
  `Ash.Policy.Authorizer`. `Cadence.Server.Passkeys` scopes every read and
  mutation by `user_id`. The credential id, public key, AAGUID, sign count,
  and attestation type are never serialized to HTML/JSON.

  AAGUID and transports are advisory diagnostics (a model hint and a
  client-supplied transport list). They are never used for authorization.
  """

  use Ash.Resource,
    domain: Cadence.Server.Accounts,
    data_layer: AshPostgres.DataLayer

  alias Cadence.Server.Accounts.CoseKey
  alias Cadence.Server.Accounts.Validations

  @transports ~w(usb nfc ble hybrid internal smart-card)

  actions do
    defaults([:read, :destroy])

    create :create do
      description("Stores a verified registration. Callers must verify first.")
      primary?(true)

      accept([
        :user_id,
        :credential_id,
        :public_key,
        :sign_count,
        :aaguid,
        :transports,
        :attestation_type,
        :label
      ])

      validate(one_of(:attestation_type, ["none"]))
      validate({Validations.ByteSize, attribute: :credential_id, min: 1, max: 1023})
      validate({Validations.ByteSize, attribute: :aaguid, min: 16, max: 16})
      validate({Validations.Transports, attribute: :transports})
      validate({Validations.Label, attribute: :label})
    end

    update :rename do
      description("Changes the human label only.")
      accept([:label])
      require_atomic?(false)
      validate({Validations.Label, attribute: :label})
    end

    update :record_use do
      description("Advances the signature counter and last-used timestamp.")

      accept([:sign_count, :last_used_at])
      # The context applies a filter on the previous counter for compare-and-swap
      # semantics; custom validations must run in the same transaction.
      require_atomic?(false)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :credential_id, :binary do
      allow_nil?(false)
      public?(false)
      sensitive?(true)
    end

    attribute :public_key, CoseKey do
      allow_nil?(false)
      public?(false)
      sensitive?(true)
    end

    attribute :sign_count, :integer do
      allow_nil?(false)
      default(0)
      public?(false)
      sensitive?(true)
      constraints(min: 0)
    end

    attribute :aaguid, :binary do
      allow_nil?(true)
      public?(false)
      sensitive?(true)
    end

    attribute :transports, {:array, :string} do
      allow_nil?(false)
      default([])
      public?(true)
    end

    attribute :attestation_type, :string do
      allow_nil?(false)
      default("none")
      public?(false)
      sensitive?(true)
    end

    attribute :label, :string do
      allow_nil?(false)
      default("Security key")
      public?(true)
      constraints(max_length: 60, length_count: :graphemes, allow_empty?: false)
    end

    attribute :last_used_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    timestamps(public?: true)
  end

  relationships do
    belongs_to :user, Cadence.Server.Accounts.User do
      allow_nil?(false)
    end
  end

  identities do
    identity(:unique_credential_id, [:credential_id])
  end

  postgres do
    table("webauthn_credentials")
    repo(Cadence.Server.Repo)

    references do
      reference(:user, on_delete: :delete)
    end

    custom_indexes do
      index([:user_id])
    end
  end

  @doc "The transport values accepted from the browser (plan §7.2)."
  def transports, do: @transports
end
