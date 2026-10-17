defmodule Cadence.Server.Accounts.User do
  @moduledoc """
  A human Cadence server user (spec §4.3, §7.4).

  Authentication is delegated to AshAuthentication: GitHub/Google OAuth for
  humans and API keys for daemons. The resource stores only identity metadata;
  daemon keys live in `Cadence.Server.Accounts.ApiKey`.
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

    timestamps()
  end

  identities do
    identity(:unique_email, [:email])
  end

  relationships do
    has_many :valid_api_keys, Cadence.Server.Accounts.ApiKey do
      filter(expr(valid))
    end
  end

  actions do
    defaults([:read])

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
