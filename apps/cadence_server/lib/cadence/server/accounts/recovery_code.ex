defmodule Cadence.Server.Accounts.RecoveryCode do
  @moduledoc """
  A one-use TOTP recovery code (spec §7.4).

  Only the SHA-256 hash of the normalized code is stored. The code is shown to
  the user once, at enrollment or regeneration, and never again.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "user_recovery_codes" do
    field(:code_hash, :binary, redact: true)
    field(:used_at, :utc_datetime)
    field(:user_id, :binary_id)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "Whether this code has already been consumed."
  def used?(%__MODULE__{used_at: %DateTime{}}), do: true
  def used?(_), do: false
end
