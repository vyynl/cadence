defmodule Cadence.Shared.Membership do
  @moduledoc """
  A user's membership in a project (spec §4.3 + §4.5/§4.6).

  Composite primary key of `(user_id, project_id)`. `active_heads` and
  `session_pointer` are user-preference metadata that sync between machines;
  `approver`, `team`, and `supervisor` are lightweight, metadata-grade
  collaboration fields (§4.6).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Cadence.Shared.Changeset, as: SharedChangeset

  @primary_key false

  @roles [:owner, :trusted, :viewer]

  schema "memberships" do
    field(:user_id, Ecto.UUID, primary_key: true)
    field(:project_id, Ecto.UUID, primary_key: true)
    field(:role, Ecto.Enum, values: @roles)
    field(:approver, :boolean, default: false)
    field(:team, :string)
    field(:supervisor, Ecto.UUID)
    field(:active_heads, {:array, Ecto.UUID}, default: [])
    field(:session_pointer, Ecto.UUID)
    field(:last_seen_at, :utc_datetime)
  end

  @doc """
  Builds a `Membership` changeset.

  Requires `user_id`, `project_id`, and `role`; validates `role` is a known
  role and the UUID-format fields.
  """
  def changeset(membership \\ %__MODULE__{}, attrs) do
    membership
    |> cast(attrs, [
      :user_id,
      :project_id,
      :role,
      :approver,
      :team,
      :supervisor,
      :active_heads,
      :session_pointer,
      :last_seen_at
    ])
    |> validate_required([:user_id, :project_id, :role])
    |> validate_inclusion(:role, @roles)
    |> SharedChangeset.validate_uuid([:user_id, :project_id, :supervisor, :session_pointer])
  end
end
