defmodule Cadence.Server.Accounts.ApiKey do
  @moduledoc """
  A daemon personal access token (spec §10.1).

  The plaintext key is returned exactly once by
  `AshAuthentication.Strategy.ApiKey.GenerateApiKey`; only a hash is stored.
  """

  use Ash.Resource,
    domain: Cadence.Server.Accounts,
    data_layer: AshPostgres.DataLayer

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:user_id, :name, :expires_at])

      change(
        {AshAuthentication.Strategy.ApiKey.GenerateApiKey, prefix: :cad, hash: :api_key_hash}
      )
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :name, :string do
      public?(true)
    end

    attribute :api_key_hash, :binary do
      allow_nil?(false)
      sensitive?(true)
    end

    attribute :expires_at, :utc_datetime_usec

    timestamps()
  end

  relationships do
    belongs_to :user, Cadence.Server.Accounts.User do
      allow_nil?(false)
    end
  end

  calculations do
    calculate(:valid, :boolean, expr(is_nil(expires_at) or expires_at > now()))
  end

  identities do
    identity(:unique_api_key, [:api_key_hash])
  end

  postgres do
    table("api_keys")
    repo(Cadence.Server.Repo)
  end
end
