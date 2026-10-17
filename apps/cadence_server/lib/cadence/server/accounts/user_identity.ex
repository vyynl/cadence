defmodule Cadence.Server.Accounts.UserIdentity do
  @moduledoc """
  OAuth issuer/subject identities linked to a Cadence user (spec §7.4).

  AshAuthentication generates the attributes; the resource only needs the user
  relationship and data-layer configuration.
  """

  use Ash.Resource,
    domain: Cadence.Server.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication.UserIdentity]

  user_identity do
    user_resource(Cadence.Server.Accounts.User)
  end

  postgres do
    table("user_identities")
    repo(Cadence.Server.Repo)
  end
end
