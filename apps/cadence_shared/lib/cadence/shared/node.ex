defmodule Cadence.Shared.Node do
  @moduledoc """
  A node in a project's DAG — one immutable session snapshot.

  Mirrors spec §4.1. `parents` is stored as a `uuid[]` array (GIN-indexed in
  Postgres; the documented migration path is a normalized `node_edges` table).
  `session_metadata` stays small: diffs are referenced by SHA, never inlined.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Cadence.Shared.Changeset, as: SharedChangeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}

  @flags [:functioning, :"in-progress", :broken, :sandbox]
  @docs_states [:current, :pending, :skipped]

  schema "nodes" do
    field(:project_id, Ecto.UUID)
    field(:git_commit_sha, :string)
    field(:parents, {:array, Ecto.UUID}, default: [])
    field(:flags, {:array, Ecto.Enum}, values: @flags, default: [])
    field(:pinned, :boolean, default: false)
    field(:message, :string)
    field(:session_metadata, :map, default: %{})
    field(:created_by, Ecto.UUID)
    field(:created_at, :utc_datetime_usec)
    field(:docs_state, Ecto.Enum, values: @docs_states)
  end

  @doc """
  Builds a `Node` changeset.

  Validates required fields, restricts `flags` to the known flag set and
  `docs_state` to the known states, and checks UUID-format fields.
  """
  def changeset(node \\ %__MODULE__{}, attrs) do
    node
    |> cast(attrs, [
      :id,
      :project_id,
      :git_commit_sha,
      :parents,
      :flags,
      :pinned,
      :message,
      :session_metadata,
      :created_by,
      :created_at,
      :docs_state
    ])
    |> validate_required([:project_id, :git_commit_sha, :created_by, :docs_state])
    |> SharedChangeset.validate_uuid([:project_id, :created_by])
    |> validate_subset(:flags, @flags)
    |> validate_inclusion(:docs_state, @docs_states)
    |> validate_format(:git_commit_sha, ~r/^[0-9a-f]{40}$/)
  end
end
