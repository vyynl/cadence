defmodule Cadence.Daemon.Repo.Migrations.DropActionsManifestFromProjects do
  use Ecto.Migration

  # The shared `Project` schema no longer has `actions_manifest` (spec §4.2/§16);
  # actions are read from the selected node snapshot. Reversible: `down` re-adds
  # an empty nullable map column.
  def change do
    alter table(:projects) do
      remove(:actions_manifest, :map)
    end
  end
end
