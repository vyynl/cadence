defmodule Cadence.Server.Repo.Migrations.CreateUserRecoveryCodes do
  @moduledoc """
  One-use TOTP recovery codes (spec §7.4).

  Only the SHA-256 hash of a normalized code is stored, so a database dump
  cannot be replayed as a recovery code. `used_at` is the single-use marker.
  """

  use Ecto.Migration

  def change do
    create table(:user_recovery_codes, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:code_hash, :binary, null: false)
      add(:used_at, :utc_datetime)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(index(:user_recovery_codes, [:user_id]))
    create(unique_index(:user_recovery_codes, [:user_id, :code_hash]))
  end
end
