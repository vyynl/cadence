defmodule Cadence.Daemon.Repo.Migrations.CreateSyncTables do
  use Ecto.Migration

  def up do
    create table(:sync_pending, primary_key: false) do
      add(:node_id, :binary_id, primary_key: true)
      add(:project_id, :binary_id, null: false)
      add(:enqueued_at, :utc_datetime_usec, null: false)
      add(:attempts, :integer, null: false, default: 0)
      add(:last_error, :text)
      add(:next_attempt_at, :utc_datetime_usec, null: false)
    end

    create(index(:sync_pending, [:project_id, :enqueued_at]))
    create(index(:sync_pending, [:next_attempt_at]))

    create table(:sync_cursors, primary_key: false) do
      add(:project_id, :binary_id, primary_key: true)
      add(:cursor, :text, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create table(:sync_state, primary_key: false) do
      add(:key, :string, primary_key: true)
      add(:value, :text, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    # Upgrade path: nodes committed before sync existed are still local-only.
    # Seed them as pending so a first sync sends the whole local DAG. The
    # ledger's backfill marker makes app-level rehydrate a no-op afterwards.
    execute("""
    INSERT INTO sync_pending
      (node_id, project_id, enqueued_at, attempts, last_error, next_attempt_at)
    SELECT
      id,
      project_id,
      COALESCE(created_at, strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
      0,
      NULL,
      COALESCE(created_at, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
    FROM nodes
    """)
  end

  def down do
    drop(table(:sync_state))
    drop(table(:sync_cursors))
    drop(table(:sync_pending))
  end
end
