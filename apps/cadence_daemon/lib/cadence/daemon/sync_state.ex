defmodule Cadence.Daemon.SyncState do
  @moduledoc """
  Small key/value store for daemon sync bookkeeping (server user ID, backfill
  marker, and future sync settings).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:key, :string, autogenerate: false}

  schema "sync_state" do
    field(:value, :string)
    field(:updated_at, :utc_datetime_usec)
  end

  def changeset(state \\ %__MODULE__{}, attrs) do
    state
    |> cast(attrs, [:key, :value, :updated_at])
    |> validate_required([:key, :value, :updated_at])
  end
end
