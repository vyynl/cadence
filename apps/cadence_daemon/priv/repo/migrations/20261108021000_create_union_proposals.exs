defmodule Cadence.Daemon.Repo.Migrations.CreateUnionProposals do
  use Ecto.Migration

  def change do
    create table(:union_proposals, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:project_id, :binary_id, null: false)
      add(:token, :string, null: false)
      add(:kind, :string)
      add(:status, :string)
      add(:parent_node_ids, {:array, :binary_id}, null: false, default: [])
      add(:created_at, :utc_datetime_usec, null: false)
    end

    create(index(:union_proposals, [:project_id, :created_at]))
  end
end
