defmodule Cadence.Server.Repo.Migrations.AddMembershipPreferencesUpdatedAt do
  use Ecto.Migration

  def change do
    alter table(:memberships) do
      add(:preferences_updated_at, :utc_datetime_usec)
    end
  end
end
