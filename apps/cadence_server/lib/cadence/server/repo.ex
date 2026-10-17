defmodule Cadence.Server.Repo do
  @moduledoc """
  The server's Postgres repository.

  Backed by `AshPostgres.Repo` so Ash resources and the shared Ecto schemas
  (`Cadence.Shared.Node`, `.Project`, `.Membership`) share one adapter and
  connection pool.
  """

  use AshPostgres.Repo, otp_app: :cadence_server

  @impl true
  def installed_extensions do
    ["ash-functions", "citext"]
  end

  @impl true
  def min_pg_version do
    %Version{major: 16, minor: 0, patch: 0}
  end
end
