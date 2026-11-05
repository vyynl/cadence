defmodule Cadence.Server.Repo.Migrations.AddResultMetadataToProposals do
  @moduledoc """
  Records reproducible AI metadata for meld proposals and allows open incidents
  to be scoped to a project alone (spec §6.5, §6.7, §9).

  `proposals.result_metadata` is server-owned jsonb: provider, model, prompt
  version, and conflict/operation counts for the meld that produced the
  proposal. It is never cast from client input.

  The partial unique index mirrors the existing proposal/node incident indexes:
  one open incident per `(project, kind)` when neither a proposal nor a node is
  referenced, so a retried meld failure does not duplicate alerts.
  """

  use Ecto.Migration

  def change do
    alter table(:proposals) do
      add(:result_metadata, :map, null: false, default: %{})
    end

    create(
      unique_index(:incidents, [:project_id, :kind],
        where: "status = 'open' and proposal_id is null and node_id is null",
        name: :incidents_open_project_kind_index
      )
    )
  end
end
