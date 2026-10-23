defmodule Cadence.Daemon.Repo.Migrations.BackfillProjectCreatedAt do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE projects
    SET created_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
    WHERE created_at IS NULL
    """)
  end

  def down do
    :ok
  end
end
