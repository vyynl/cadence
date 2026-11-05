defmodule Cadence.Server.Accounts.User do
  @moduledoc """
  A human Cadence server user (spec §4.3, §7.4).

  Authentication is delegated to AshAuthentication: GitHub/Google OAuth for
  humans and API keys for daemons. The resource stores only identity metadata;
  daemon keys live in `Cadence.Server.Accounts.ApiKey`.

  When the `:demo_auth` build flag is true, a password strategy (`:demo`) is
  compiled in for the local demo stack. The flag is read at build time
  (`CAD_DEMO_AUTH`) so a production build cannot contain a password login;
  `config/runtime.exs` refuses to boot a prod release with the flag set.
  Registration is never enabled — demo users are seeded.
  """

  use Ash.Resource,
    domain: Cadence.Server.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication]

  require Ash.Resource.Change.Builtins

  @demo_auth Application.compile_env(:cadence_server, :demo_auth, false)

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

      if @demo_auth do
        password :demo do
          identity_field(:email)
          hashed_password_field(:hashed_password)
          registration_enabled?(false)
          sign_in_enabled?(true)
        end
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

    create :create do
      description("Internal create action for demo users and seeding.")

      accept([:email, :name, :hashed_password])
      require_attributes([:hashed_password])
      validate(match(:hashed_password, ~r/^\$2[aby]\$/))
      change(set_attribute(:confirmed_at, &DateTime.utc_now/0))
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
