defmodule Cadence.Server.Repo.Migrations.AddActionRunsQueueIndex do
  @moduledoc """
  Back the per-project run queue (spec §8.3).

  The claim reads the oldest `:queued` row for a project and counts `:running`
  rows. Both are served by a `(project_id, status, created_at)` index, which is
  a strict prefix improvement over the old `(project_id, status)` index used by
  the run list.
  """

  use Ecto.Migration

  def up do
    drop(index(:action_runs, [:project_id, :status]))
    create(index(:action_runs, [:project_id, :status, :created_at]))
  end

  def down do
    drop(index(:action_runs, [:project_id, :status, :created_at]))
    create(index(:action_runs, [:project_id, :status]))
  end
end
