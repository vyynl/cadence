defmodule Cadence.Daemon.SyncPreference do
  @moduledoc """
  Per-project preference sync state (daemon-only).

  Tracks the last local version successfully pushed and the last remote version
  applied. Local dirtiness is derived by comparing the membership's
  `preferences_updated_at` with `pushed_updated_at`; there is no separate dirty
  flag.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:project_id, Ecto.UUID, autogenerate: false}

  schema "sync_preferences" do
    field(:pushed_updated_at, :utc_datetime_usec)
    field(:remote_updated_at, :utc_datetime_usec)
    field(:last_error, :string)
    field(:updated_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          project_id: Ecto.UUID.t() | nil,
          pushed_updated_at: DateTime.t() | nil,
          remote_updated_at: DateTime.t() | nil,
          last_error: String.t() | nil,
          updated_at: DateTime.t() | nil
        }

  def changeset(preference \\ %__MODULE__{}, attrs) do
    preference
    |> cast(attrs, [:project_id, :pushed_updated_at, :remote_updated_at, :last_error, :updated_at])
    |> validate_required([:project_id, :updated_at])
  end
end
