defmodule Cadence.Daemon.UnionProposal do
  @moduledoc """
  A union proposal created from this daemon (daemon-only).

  The server owns proposals and their decisions; this is a small local journal
  of the proposal reference returned by `POST /sync/union`, so the Neovim
  `:CadProposals` list can recover the public token after the one-shot
  notification. `status` is the state at creation and is never refreshed — the
  public proposal page is the live source of truth.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: false}

  schema "union_proposals" do
    field(:project_id, Ecto.UUID)
    field(:token, :string)
    field(:kind, :string)
    field(:status, :string)
    field(:parent_node_ids, {:array, Ecto.UUID}, default: [])
    field(:created_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          token: String.t() | nil,
          kind: String.t() | nil,
          status: String.t() | nil,
          parent_node_ids: [Ecto.UUID.t()],
          created_at: DateTime.t() | nil
        }

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(proposal \\ %__MODULE__{}, attrs) do
    proposal
    |> cast(attrs, [:id, :project_id, :token, :kind, :status, :parent_node_ids, :created_at])
    |> validate_required([:id, :project_id, :token, :created_at])
    |> validate_length(:token, min: 1, max: 255)
  end
end
