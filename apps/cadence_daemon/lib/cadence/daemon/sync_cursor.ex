defmodule Cadence.Daemon.SyncCursor do
  @moduledoc """
  Per-project cloud pull cursor (daemon-only).

  The cursor is the server's opaque `nodes.seq` value. It is stored separately
  from pending pushes so a project can pull even when it has nothing to push.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:project_id, Ecto.UUID, autogenerate: false}

  schema "sync_cursors" do
    field(:cursor, :string)
    field(:updated_at, :utc_datetime_usec)
  end

  def changeset(cursor \\ %__MODULE__{}, attrs) do
    cursor
    |> cast(attrs, [:project_id, :cursor, :updated_at])
    |> validate_required([:project_id, :cursor, :updated_at])
  end
end
