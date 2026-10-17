defmodule Cadence.Server.Accounts do
  @moduledoc """
  Server-side accounts: OAuth identities and daemon API keys.

  Human users authenticate with GitHub or Google; daemons authenticate with
  personal access tokens modelled as AshAuthentication API keys (spec §7.4,
  §10.1).
  """

  use Ash.Domain

  resources do
    resource(Cadence.Server.Accounts.User)
    resource(Cadence.Server.Accounts.Token)
    resource(Cadence.Server.Accounts.UserIdentity)
    resource(Cadence.Server.Accounts.ApiKey)
  end

  @doc """
  Issues a personal access token for a daemon.

  The plaintext key is available exactly once in
  `api_key.__metadata__.plaintext_api_key`; only its hash is persisted.
  """
  def create_api_key(user, name) do
    Ash.create(
      Cadence.Server.Accounts.ApiKey,
      %{user_id: user.id, name: name},
      action: :create,
      actor: user
    )
  end
end
