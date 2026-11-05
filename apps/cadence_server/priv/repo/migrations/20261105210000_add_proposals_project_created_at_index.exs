defmodule Cadence.Server.Repo.Migrations.AddProposalsProjectCreatedAtIndex do
  @moduledoc """
  Covers the review queue's `WHERE project_id = ? ORDER BY created_at, id`
  query (proposals list and demo summary) without a sort step.
  """

  use Ecto.Migration

  def change do
    create(index(:proposals, [:project_id, :created_at]))
  end
end
