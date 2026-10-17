defmodule Cadence.Server.Accounts.Token do
  @moduledoc """
  AshAuthentication token storage (JWT sessions for OAuth users).
  """

  use Ash.Resource,
    domain: Cadence.Server.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication.TokenResource]

  postgres do
    table("tokens")
    repo(Cadence.Server.Repo)
  end
end
