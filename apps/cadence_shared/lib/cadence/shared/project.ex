defmodule Cadence.Shared.Project do
  @moduledoc """
  A Cadence project (spec §4.2).

  Owns the DAG of `Cadence.Shared.Node`s and carries docs/actions metadata.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Cadence.Shared.Changeset, as: SharedChangeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}

  schema "projects" do
    field(:name, :string)
    field(:slug, :string)
    field(:owner_id, Ecto.UUID)
    field(:docs_schema, :map, default: %{})
    field(:docker_image, :string)
    field(:actions_manifest, :map)
    field(:created_at, :utc_datetime)
  end

  @doc """
  Builds a `Project` changeset.

  Requires `name`, `slug`, and `owner_id`; validates `slug` is URL-safe and
  `owner_id` is a UUID.
  """
  def changeset(project \\ %__MODULE__{}, attrs) do
    project
    |> cast(attrs, [
      :id,
      :name,
      :slug,
      :owner_id,
      :docs_schema,
      :docker_image,
      :actions_manifest,
      :created_at
    ])
    |> validate_required([:name, :slug, :owner_id])
    |> validate_format(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/)
    |> SharedChangeset.validate_uuid(:owner_id)
  end
end
