defmodule Cadence.Daemon.ProjectLocation do
  @moduledoc """
  Daemon-local mapping of a project to its on-disk locations.

  `work_dir` is the watched working tree; `git_dir` is the bare Git object
  store (lives under the state dir, outside the working tree). This is a
  machine-local concern, so it stays in `cadence_daemon` and is never synced.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  schema "project_locations" do
    field(:project_id, Ecto.UUID, primary_key: true)
    field(:work_dir, :string)
    field(:git_dir, :string)
    field(:created_at, :utc_datetime)
  end

  def changeset(location \\ %__MODULE__{}, attrs) do
    location
    |> cast(attrs, [:project_id, :work_dir, :git_dir, :created_at])
    |> validate_required([:project_id, :work_dir, :git_dir])
  end
end
