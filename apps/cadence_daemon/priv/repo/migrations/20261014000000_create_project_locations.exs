defmodule Cadence.Daemon.Repo.Migrations.CreateProjectLocations do
  use Ecto.Migration

  def change do
    create table(:project_locations, primary_key: false) do
      add :project_id, :binary_id, primary_key: true
      add :work_dir, :string, null: false
      add :git_dir, :string, null: false
      add :created_at, :utc_datetime
    end
  end
end
