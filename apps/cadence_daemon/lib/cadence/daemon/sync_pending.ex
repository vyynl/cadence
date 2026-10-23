defmodule Cadence.Daemon.SyncPending do
  @moduledoc """
  A node queued for upload to the cloud (daemon-only).

  Rows are keyed by node ID because node IDs are identity-mapped across the
  daemon and server. `next_attempt_at` implements retry backoff without
  deleting the node.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:node_id, Ecto.UUID, autogenerate: false}

  schema "sync_pending" do
    field(:project_id, Ecto.UUID)
    field(:enqueued_at, :utc_datetime_usec)
    field(:attempts, :integer, default: 0)
    field(:last_error, :string)
    field(:next_attempt_at, :utc_datetime_usec)
  end

  def changeset(pending \\ %__MODULE__{}, attrs) do
    pending
    |> cast(attrs, [:node_id, :project_id, :enqueued_at, :attempts, :last_error, :next_attempt_at])
    |> validate_required([:node_id, :project_id, :enqueued_at, :next_attempt_at])
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
  end
end
