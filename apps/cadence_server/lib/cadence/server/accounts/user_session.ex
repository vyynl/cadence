defmodule Cadence.Server.Accounts.UserSession do
  @moduledoc """
  A database-backed browser session (spec §7.4).

  The raw token lives only in the signed session cookie and the signed
  remember-me cookie. This row stores its SHA-256 hash, so a database dump
  cannot be replayed.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "user_sessions" do
    field(:token_hash, :binary, redact: true)
    field(:authenticated_at, :utc_datetime)
    field(:user_id, :binary_id)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
