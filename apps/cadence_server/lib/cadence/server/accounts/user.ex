defmodule Cadence.Server.Accounts.User do
  @moduledoc """
  A human Cadence server user (spec §4.3, §7.4).

  AshAuthentication still provides the GitHub/Google OAuth strategies and the
  daemon API-key strategy. Local email/password login, TOTP, and browser
  sessions are Cadence-owned (`Cadence.Server.Accounts.LocalAuth`,
  `Cadence.Server.Accounts.TOTP`, `Cadence.ServerWeb.UserAuth`).

  Registration is never enabled. Local accounts are created by the operator
  (`mix cadence.user` / `Cadence.Server.Release.create_user/2`); the first
  password login forces TOTP enrollment.
  """

  use Ash.Resource,
    domain: Cadence.Server.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication]

  require Ash.Resource.Change.Builtins

  authentication do
    session_identifier(:jti)

    tokens do
      enabled?(true)
      token_resource(Cadence.Server.Accounts.Token)
      store_all_tokens?(true)
      signing_secret(Cadence.Server.Secrets)
    end

    strategies do
      github do
        client_id(Cadence.Server.Secrets)
        client_secret(Cadence.Server.Secrets)
        redirect_uri(Cadence.Server.Secrets)
        identity_resource(Cadence.Server.Accounts.UserIdentity)
      end

      google do
        client_id(Cadence.Server.Secrets)
        client_secret(Cadence.Server.Secrets)
        redirect_uri(Cadence.Server.Secrets)
        identity_resource(Cadence.Server.Accounts.UserIdentity)
      end

      api_key do
        api_key_relationship(:valid_api_keys)
      end
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :email, :ci_string do
      allow_nil?(false)
      public?(true)
    end

    attribute :name, :string do
      public?(true)
    end

    attribute :confirmed_at, :utc_datetime_usec

    attribute :hashed_password, :string do
      allow_nil?(true)
      sensitive?(true)
    end

    # TOTP is Cadence-owned (spec §7.4). The shared secret is stored encrypted
    # by `Cadence.Server.Security.SecretBox`; the plaintext never touches the DB.
    attribute :totp_secret, :string do
      allow_nil?(true)
      sensitive?(true)
    end

    attribute :totp_confirmed_at, :utc_datetime
    attribute :totp_last_used_at, :utc_datetime

    timestamps()
  end

  identities do
    identity(:unique_email, [:email])
  end

  relationships do
    has_many :valid_api_keys, Cadence.Server.Accounts.ApiKey do
      filter(expr(valid))
    end

    has_many :webauthn_credentials, Cadence.Server.Accounts.WebAuthnCredential
  end

  actions do
    defaults([:read])

    create :create do
      description("Internal create action for demo users and seeding.")

      accept([
        :email,
        :name,
        :hashed_password,
        :totp_secret,
        :totp_confirmed_at,
        :totp_last_used_at
      ])

      require_attributes([:hashed_password])

      # Local accounts use Argon2id; bcrypt remains accepted for any
      # pre-existing demo row that has not been reseeded yet.
      validate(match(:hashed_password, ~r/^\$(argon2id|argon2i|argon2d|2[aby])\$/))
      change(set_attribute(:confirmed_at, &DateTime.utc_now/0))
    end

    update :set_password do
      description("Set or replace a local password hash (already hashed).")
      accept([:hashed_password])
      require_attributes([:hashed_password])
      validate(match(:hashed_password, ~r/^\$(argon2id|argon2i|argon2d|2[aby])\$/))
      require_atomic?(false)
    end

    update :confirm_totp do
      description("Mark TOTP enrollment confirmed and record the first use.")
      accept([:totp_secret, :totp_confirmed_at, :totp_last_used_at])
    end

    update :mark_totp_used do
      description("Record the last accepted TOTP time step.")
      accept([:totp_last_used_at])
    end

    update :clear_totp do
      description("Remove the TOTP secret and enrollment timestamps.")
      accept([:totp_secret, :totp_confirmed_at, :totp_last_used_at])
    end

    read :get_by_subject do
      description("Get a user by the subject claim in a token")
      argument(:subject, :string, allow_nil?: false)
      get?(true)
      prepare(AshAuthentication.Preparations.FilterBySubject)
    end

    create :register_with_github do
      argument(:user_info, :map, allow_nil?: false)
      argument(:oauth_tokens, :map, allow_nil?: false, sensitive?: true)
      upsert?(true)
      upsert_identity(:unique_email)

      change(AshAuthentication.GenerateTokenChange)
      change(AshAuthentication.Strategy.OAuth2.IdentityChange)

      change(fn changeset, _ ->
        user_info = Ash.Changeset.get_argument(changeset, :user_info)

        Ash.Changeset.change_attributes(
          changeset,
          Map.take(user_info, ["email", "name"])
        )
      end)

      upsert_fields([])
      change(set_attribute(:confirmed_at, &DateTime.utc_now/0))
    end

    create :register_with_google do
      argument(:user_info, :map, allow_nil?: false)
      argument(:oauth_tokens, :map, allow_nil?: false, sensitive?: true)
      upsert?(true)
      upsert_identity(:unique_email)

      change(AshAuthentication.GenerateTokenChange)
      change(AshAuthentication.Strategy.OAuth2.IdentityChange)

      change(fn changeset, _ ->
        user_info = Ash.Changeset.get_argument(changeset, :user_info)

        Ash.Changeset.change_attributes(
          changeset,
          Map.take(user_info, ["email", "name"])
        )
      end)

      upsert_fields([])
      change(set_attribute(:confirmed_at, &DateTime.utc_now/0))
    end

    read :sign_in_with_api_key do
      argument(:api_key, :string, allow_nil?: false)
      prepare(AshAuthentication.Strategy.ApiKey.SignInPreparation)
    end
  end

  postgres do
    table("users")
    repo(Cadence.Server.Repo)
  end
end
