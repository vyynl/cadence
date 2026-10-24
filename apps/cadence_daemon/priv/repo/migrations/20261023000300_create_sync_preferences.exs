defmodule Cadence.Daemon.Repo.Migrations.CreateSyncPreferences do
  use Ecto.Migration

  def change do
    create table(:sync_preferences, primary_key: false) do
      add(:project_id, :binary_id, primary_key: true)
      add(:pushed_updated_at, :utc_datetime_usec)
      add(:remote_updated_at, :utc_datetime_usec)
      add(:last_error, :text)
      add(:updated_at, :utc_datetime_usec, null: false)
    end
  end
end
