defmodule Cadence.Server.Repo.Migrations.DropProjectActionsManifest do
  use Ecto.Migration

  # 6a reads `actions/manifest.json` from the selected node snapshot, so the
  # unused project column (spec §4.2/§16) is removed. Reversible: `down` adds an
  # empty nullable column, which is all the field ever held.
  def change do
    alter table(:projects) do
      remove(:actions_manifest, :map)
    end
  end
end
