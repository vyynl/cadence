defmodule Cadence.Daemon.Projects do
  @moduledoc """
  Registers, lists, and rehydrates local projects.

  A project is registered by persisting the `Cadence.Shared.Project` row and a
  machine-local `Cadence.Daemon.ProjectLocation`, then booting its
  `{CommitQueue, Watcher}` pair via `Cadence.Daemon.ProjectRegistry` and
  seeding the local user's owner membership.
  """

  import Ecto.Query

  require Logger

  alias Cadence.Daemon.{
    Dirs,
    Docs.SchemaSource,
    Env,
    ProjectLocation,
    ProjectRegistry,
    Repo,
    Session
  }

  alias Cadence.Shared.{GitStore, Membership, Project, UUID}

  @doc """
  Registers a project. `attrs` requires string-keyed `name`, `slug`, and
  `work_dir`. Returns `{:ok, project}` or `{:error, changeset}`.

  Options:

    * `:watch` — when `false`, persist the project, location, and membership
      without starting the `{CommitQueue, Watcher}` pair. The Git importer uses
      this so a new project has no watcher while its history is inserted, and a
      bare-repository import never starts one.
  """
  @spec register_project(map(), keyword()) ::
          {:ok, Project.t()}
          | {:error, :already_registered | :missing_work_dir | Ecto.Changeset.t() | term()}
  def register_project(%{} = attrs, opts \\ []) do
    case attrs["work_dir"] do
      dir when is_binary(dir) and dir != "" ->
        work_dir = Path.expand(dir)

        if Repo.get_by(ProjectLocation, work_dir: work_dir) do
          {:error, :already_registered}
        else
          do_register(attrs, work_dir, Keyword.get(opts, :watch, true))
        end

      _ ->
        {:error, :missing_work_dir}
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

  @doc "Project IDs with a machine-local location (the set the sync worker runs)."
  @spec list_project_ids() :: [Ecto.UUID.t()]
  def list_project_ids do
    ProjectLocation
    |> select([l], l.project_id)
    |> Repo.all()
  end

  def get_project(project_id) do
    case UUID.cast(project_id) do
      {:ok, project_id} -> Repo.get(Project, project_id)
      :error -> nil
    end
  end

  @doc """
  Restarts a `{CommitQueue, Watcher}` pair for every persisted project location
  that isn't already running. Failures are logged per project.
  """
  def rehydrate do
    ProjectLocation
    |> Repo.all()
    |> Enum.each(fn loc ->
      project = Repo.get(Project, loc.project_id)

      if ProjectRegistry.lookup_queue(loc.project_id) == nil and not is_nil(project) and
           watchable?(loc) do
        case ProjectRegistry.start_project(
               project_id: loc.project_id,
               work_dir: loc.work_dir,
               git_dir: loc.git_dir
             ) do
          {:ok, _pid} ->
            :ok

          {:error, reason} ->
            Logger.error("failed to rehydrate project #{loc.project_id}: #{inspect(reason)}")
        end
      end
    end)

    :ok
  rescue
    e in Exqlite.Error ->
      if missing_table?(e) do
        Logger.warning("project rehydrate skipped before migrations: #{Exception.message(e)}")
        :ok
      else
        reraise e, __STACKTRACE__
      end
  end

  # A bare-repository import has no working tree to watch or snapshot. Starting
  # the pair would let a ref/object change inside the bare repo become a node,
  # so these projects are restored as data-only (sync still works from the
  # location row).
  defp watchable?(%ProjectLocation{} = loc) do
    not match?({:ok, %{kind: :bare}}, GitStore.detect_repository(loc.work_dir))
  end

  defp missing_table?(error) do
    String.contains?(Exception.message(error), "no such table")
  end

  defp do_register(attrs, work_dir, watch?) do
    project_attrs = %{
      name: attrs["name"],
      slug: attrs["slug"],
      owner_id: attrs["owner_id"] || Env.local_user_id()
    }

    result =
      Repo.transaction(fn ->
        project = insert_project!(project_attrs)
        git_dir = Path.join(Dirs.git_root(), project.id)
        insert_location!(project.id, work_dir, git_dir)
        Session.ensure_membership!(project.id)
        %{project: project, git_dir: git_dir}
      end)

    with {:ok, %{project: project, git_dir: git_dir}} <- result do
      # Best-effort: the working-tree file remains the source of truth.
      _ = SchemaSource.refresh(project.id, work_dir)

      if watch? do
        start_project(project, work_dir, git_dir)
      else
        {:ok, project}
      end
    end
  end

  defp start_project(project, work_dir, git_dir) do
    case ProjectRegistry.start_project(
           project_id: project.id,
           work_dir: work_dir,
           git_dir: git_dir
         ) do
      {:ok, _pid} ->
        {:ok, project}

      {:error, {:already_started, _pid}} ->
        {:ok, project}

      {:error, reason} ->
        cleanup_project(project.id)
        {:error, reason}
    end
  end

  defp insert_project!(attrs) do
    case %Project{} |> Project.changeset(attrs) |> Repo.insert() do
      {:ok, project} -> project
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp insert_location!(project_id, work_dir, git_dir) do
    %ProjectLocation{}
    |> ProjectLocation.changeset(%{
      project_id: project_id,
      work_dir: work_dir,
      git_dir: git_dir,
      created_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp cleanup_project(project_id) do
    Repo.transaction(fn ->
      Repo.delete_all(from(m in Membership, where: m.project_id == ^project_id))
      Repo.delete_all(from(l in ProjectLocation, where: l.project_id == ^project_id))
      Repo.delete_all(from(p in Project, where: p.id == ^project_id))
    end)
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
