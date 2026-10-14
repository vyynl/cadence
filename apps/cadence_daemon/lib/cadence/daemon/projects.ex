defmodule Cadence.Daemon.Projects do
  @moduledoc """
  Registers, lists, and rehydrates local projects.

  A project is registered by persisting the `Cadence.Shared.Project` row and a
  machine-local `Cadence.Daemon.ProjectLocation`, then booting its
  `{CommitQueue, Watcher}` pair via `Cadence.Daemon.ProjectRegistry` and
  seeding the local user's owner membership.
  """

  import Ecto.Query

  alias Cadence.Daemon.{Dirs, Env, ProjectLocation, ProjectRegistry, Repo, Session}
  alias Cadence.Shared.Project

  @doc """
  Registers a project. `attrs` requires string-keyed `name`, `slug`, and
  `work_dir`. Returns `{:ok, project}` or `{:error, changeset}`.
  """
  def register_project(%{} = attrs) do
    case attrs["work_dir"] do
      dir when is_binary(dir) and dir != "" -> do_register(attrs)
      _ -> {:error, :missing_work_dir}
    end
  end

  def list_projects do
    Project
    |> join(:left, [p], l in ProjectLocation, on: l.project_id == p.id)
    |> order_by([p], asc: p.name)
    |> select([p, l], {p, l})
    |> Repo.all()
    |> Enum.map(&serialize/1)
  end

  def get_project(project_id) do
    Repo.get(Project, project_id)
  end

  @doc """
  Restarts a `{CommitQueue, Watcher}` pair for every persisted project location
  that isn't already running. Best-effort: no-op if the tables are missing.
  """
  def rehydrate do
    ProjectLocation
    |> Repo.all()
    |> Enum.each(fn loc ->
      if ProjectRegistry.lookup_queue(loc.project_id) == nil do
        if Repo.get(Project, loc.project_id) do
          ProjectRegistry.start_project(
            project_id: loc.project_id,
            work_dir: loc.work_dir,
            git_dir: loc.git_dir
          )
        end
      end
    end)

    :ok
  rescue
    _ -> :ok
  end

  defp do_register(attrs) do
    work_dir = Path.expand(attrs["work_dir"])

    project_attrs = %{
      name: attrs["name"],
      slug: attrs["slug"],
      owner_id: attrs["owner_id"] || Env.local_user_id()
    }

    case %Project{} |> Project.changeset(project_attrs) |> Repo.insert() do
      {:ok, project} ->
        git_dir = Path.join(Dirs.git_root(), project.id)

        %ProjectLocation{}
        |> ProjectLocation.changeset(%{
          project_id: project.id,
          work_dir: work_dir,
          git_dir: git_dir,
          created_at: DateTime.utc_now()
        })
        |> Repo.insert!()

        ProjectRegistry.start_project(
          project_id: project.id,
          work_dir: work_dir,
          git_dir: git_dir
        )

        Session.ensure_membership!(project.id)
        {:ok, project}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp serialize({project, location}) do
    %{
      id: project.id,
      name: project.name,
      slug: project.slug,
      owner_id: project.owner_id,
      created_at: project.created_at,
      work_dir: location && location.work_dir,
      git_dir: location && location.git_dir
    }
  end
end
