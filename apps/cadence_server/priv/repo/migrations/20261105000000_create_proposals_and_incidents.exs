defmodule Cadence.Server.Repo.Migrations.CreateProposalsAndIncidents do
  @moduledoc """
  Server-side review state: proposals for pending melds/promotions, and
  incidents for critical findings that block promotion (spec §6.6, §6.7).

  Proposals and incidents are server-only; daemons do not consume them. There
  are intentionally no foreign keys, matching the existing core tables.
  """

  use Ecto.Migration

  def change do
    create table(:proposals, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:token, :string, null: false)
      add(:project_id, :binary_id, null: false)
      add(:proposer_id, :binary_id, null: false)
      add(:kind, :string, null: false)
      add(:parent_ids, {:array, :binary_id}, null: false, default: [])
      add(:target_node_id, :binary_id)
      add(:result_tree_sha, :string)
      add(:meld_commit_sha, :string)
      add(:status, :string, null: false, default: "pending")
      add(:reviewer_id, :binary_id)
      add(:decided_at, :utc_datetime_usec)
      add(:created_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:proposals, [:token]))
    create(index(:proposals, [:project_id]))
    create(index(:proposals, [:project_id, :status]))
    create(index(:proposals, [:target_node_id]))

    create table(:incidents, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:project_id, :binary_id, null: false)
      add(:proposal_id, :binary_id)
      add(:node_id, :binary_id)
      add(:kind, :string, null: false)
      add(:severity, :string, null: false, default: "critical")
      add(:status, :string, null: false, default: "open")
      add(:title, :string, null: false)
      add(:details, :map, null: false, default: %{})
      add(:created_at, :utc_datetime_usec, null: false)
      add(:resolved_at, :utc_datetime_usec)
      add(:resolved_by, :binary_id)
    end

    create(index(:incidents, [:project_id]))
    create(index(:incidents, [:project_id, :status]))
    create(index(:incidents, [:proposal_id]))
    create(index(:incidents, [:node_id]))

    create(
      unique_index(:incidents, [:proposal_id, :kind],
        where: "status = 'open' and proposal_id is not null",
        name: :incidents_open_proposal_kind_index
      )
    )

    create(
      unique_index(:incidents, [:node_id, :kind],
        where: "status = 'open' and node_id is not null",
        name: :incidents_open_node_kind_index
      )
    )
  end
end
