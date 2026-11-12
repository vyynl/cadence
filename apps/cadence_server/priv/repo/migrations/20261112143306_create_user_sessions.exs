defmodule Cadence.Server.Repo.Migrations.CreateUserSessions do
  @moduledoc """
  Database-backed browser sessions (spec §7.4).

  The cookie carries a random 32-byte token; only its SHA-256 hash is stored,
  so a database dump cannot be replayed as a live session. `authenticated_at`
  is the last fresh authentication (login, or a sudo re-auth) and drives the
  sudo window; `inserted_at` drives expiry and the 7-day rotation.
  """

  use Ecto.Migration

  def change do
    create table(:user_sessions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:token_hash, :binary, null: false)
      add(:authenticated_at, :utc_datetime, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:user_sessions, [:token_hash]))
    create(index(:user_sessions, [:user_id]))
  end
end
