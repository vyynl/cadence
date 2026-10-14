defmodule Cadence.Daemon.Repo.Migrations.CreateCoreTables do
  use Ecto.Migration

  def change do
    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :owner_id, :binary_id, null: false
      add :docs_schema, :map
      add :docker_image, :string
      add :actions_manifest, :map
      add :created_at, :utc_datetime
    end

    create unique_index(:projects, [:slug])

    create table(:nodes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, :binary_id, null: false
      add :git_commit_sha, :string, null: false
      add :parents, {:array, :binary_id}, null: false
      add :flags, {:array, :string}, null: false
      add :pinned, :boolean, default: false, null: false
      add :message, :string
      add :session_metadata, :map, null: false
      add :created_by, :binary_id, null: false
      add :created_at, :utc_datetime_usec
      add :docs_state, :string, null: false
    end

    create index(:nodes, [:project_id])
    create index(:nodes, [:project_id, :created_at])

    create table(:memberships, primary_key: false) do
      add :user_id, :binary_id, primary_key: true, null: false
      add :project_id, :binary_id, primary_key: true, null: false
      add :role, :string, null: false
      add :approver, :boolean, default: false, null: false
      add :team, :string
      add :supervisor, :binary_id
      add :active_heads, {:array, :binary_id}, null: false
      add :session_pointer, :binary_id
      add :last_seen_at, :utc_datetime
    end
  end
end
