defmodule Cadence.Daemon.Repo.Migrations.AddUnionProposalUrl do
  use Ecto.Migration

  # The server now returns the public proposal URL with the union response
  # (spec §6.5/§16), so the journal can survive a restart without assuming the
  # daemon's API base is publicly reachable. Old rows are nil and fall back to
  # the derived URL.
  def change do
    alter table(:union_proposals) do
      add(:url, :string)
    end
  end
end
