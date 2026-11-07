defmodule Cadence.Server.Repo.Migrations.CreateActionRuns do
  @moduledoc """
  Durable Docker action runs (spec §8, Phase 6b).

  Server-only, like proposals/incidents: daemons never consume runs. The row is
  written before the container starts so an interrupted server leaves an honest
  record (`:interrupted`) instead of a silent failure. No foreign keys, matching
  the existing core tables.
  """

  use Ecto.Migration

  def change do
    create table(:action_runs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:project_id, :binary_id, null: false)
      add(:node_id, :binary_id, null: false)
      add(:user_id, :binary_id, null: false)
      add(:action_name, :string, null: false)
      add(:command, :string, null: false)
      add(:status, :string, null: false, default: "queued")
      add(:exit_code, :integer)
      add(:image, :string)
      add(:container_id, :string)
      add(:error_reason, :string)
      add(:log_path, :string)
      add(:artifact_path, :string)
      add(:artifact_error, :string)
      add(:created_at, :utc_datetime_usec, null: false)
      add(:started_at, :utc_datetime_usec)
      add(:finished_at, :utc_datetime_usec)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(index(:action_runs, [:project_id]))
    create(index(:action_runs, [:project_id, :created_at]))
    create(index(:action_runs, [:project_id, :node_id]))
    create(index(:action_runs, [:project_id, :status]))
  end
end
