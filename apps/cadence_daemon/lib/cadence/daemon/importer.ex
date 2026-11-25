defmodule Cadence.Daemon.Importer do
  @moduledoc """
  Imports an existing local Git repository into a Cadence project (spec §13
  Phase 9; the normative §5.7 text lands with 9e).

  `submit/1` validates the source, resolves the selected refs, walks the
  commit graph, and preflights blob sizes synchronously, so the socket API can
  answer typed validation errors before anything is written. The object copy
  and node insert then run as a supervised job, one at a time, with progress
  from `status/1`.

  Nothing about the source history is rewritten: every node keeps the original
  commit SHA, message, author timestamp, and parents (merges preserved).
  Imported nodes carry the `:imported` provenance flag (never `functioning`)
  and `docs_state: :skipped`, with provenance under
  `session_metadata["import"]`. The selected refs are recorded on tip nodes
  only, so a repository with hundreds of refs does not repeat them on every
  node.

  A job is idempotent by `(project_id, git_commit_sha)`: a re-run adds only the
  commits the project is missing. A project that has nodes but none of them
  imported is refused (`:project_not_importable`); an import-created project
  may keep growing with ordinary commits.

  Jobs run one at a time; at most 20 may be queued/running across all projects,
  and a retry for the same source while a job is active is refused.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias Cadence.Daemon.{
    CommitQueue,
    Env,
    ProjectLocation,
    ProjectRegistry,
    Projects,
    Repo,
    Session,
    SyncLedger,
    Watcher
  }

  alias Cadence.Shared.{GitStore, Node, Project, UUID}

  @max_pending 20
  @keep_jobs 50
  @default_message "import: local changes"

  defstruct jobs: %{}, order: [], queue: :queue.new(), running: nil

  @type job_status :: :queued | :running | :completed | :failed

  @type job :: %{
          id: Ecto.UUID.t(),
          project_id: Ecto.UUID.t(),
          project_slug: String.t(),
          source: %{path: String.t(), kind: String.t()},
          refs: [String.t()],
          tips: [String.t()],
          tip: String.t(),
          total: non_neg_integer(),
          imported: non_neg_integer(),
          reused: non_neg_integer(),
          objects: non_neg_integer(),
          bytes: non_neg_integer(),
          largest_node_bytes: non_neg_integer(),
          shallow: boolean(),
          status: job_status(),
          error: map() | nil,
          created_at: DateTime.t(),
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          tip_node_id: Ecto.UUID.t() | nil,
          dirty_node_id: Ecto.UUID.t() | nil
        }

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Validates and queues an import.

  Accepts string- or atom-keyed attributes: `work_dir` (required), `project_id`,
  `name`, `slug`, `refs`, `all_refs`, `allow_shallow`, `limit`. Returns
  `{:ok, job}` for a queued job or `{:error, reason}` for a typed validation
  failure.
  """
  @spec submit(map()) :: {:ok, job()} | {:error, term()}
  def submit(attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    with {:ok, source} <- safe_prepare(attrs) do
      try do
        GenServer.call(__MODULE__, {:enqueue, attrs, source}, 30_000)
      catch
        :exit, _reason -> {:error, :not_available}
      end
    end
  end

  def submit(_attrs), do: {:error, :invalid_payload}

  @doc "Returns a job's public state, or `{:error, :not_found}`."
  @spec status(Ecto.UUID.t() | String.t()) :: {:ok, job()} | {:error, :not_found}
  def status(job_id) do
    case UUID.cast(job_id) do
      {:ok, job_id} -> GenServer.call(__MODULE__, {:status, job_id})
      :error -> {:error, :not_found}
    end
  catch
    :exit, _reason -> {:error, :not_found}
  end

  @doc "Returns all retained jobs, newest first."
  @spec list() :: [job()]
  def list do
    GenServer.call(__MODULE__, :list)
  catch
    :exit, _reason -> []
  end

  @doc """
  JSON-ready job representation (drops the internal plan).
  """
  @spec job_json(job()) :: map()
  def job_json(job) do
    %{
      id: job.id,
      status: Atom.to_string(job.status),
      project_id: job.project_id,
      project_slug: job.project_slug,
      source: job.source,
      refs: job.refs,
      tips: job.tips,
      tip: job.tip,
      total: job.total,
      merge_commits: job.merge_commits,
      imported: job.imported,
      reused: job.reused,
      objects: job.objects,
      bytes: job.bytes,
      largest_node_bytes: job.largest_node_bytes,
      shallow: job.shallow,
      error: job.error,
      tip_node_id: job.tip_node_id,
      dirty_node_id: job.dirty_node_id,
      created_at: iso8601(job.created_at),
      started_at: iso8601(job.started_at),
      finished_at: iso8601(job.finished_at)
    }
  end

  @doc """
  The synchronous import body.

  Public so the job runner is testable and a failed run can be resumed by
  re-submitting the same source. `progress` is a one-argument function called
  with partial counts.
  """
  @spec execute(map(), (map() -> any())) :: {:ok, map()} | {:error, term()}
  def execute(plan, progress) do
    target = GitStore.init(plan.git_dir, bare: true)
    token = suspension_token(plan.job_id)

    # A re-run may have a live watcher; a brand-new project has none yet (it is
    # registered without the pair). Either way, no commit may interleave with
    # the insert or the pointer move. A token scopes this suspension so a
    # concurrent doc job's resume cannot clear it.
    Watcher.suspend(plan.project_id, token)

    try do
      with {:ok, copy} <- copy_objects(plan, target),
           :ok <- report(progress, %{objects: copy.objects, bytes: copy.bytes}),
           {:ok, inserted} <- insert_nodes(plan, progress),
           :ok <- point_at_tip(plan.project_id, inserted.tip_node_id),
           {:ok, queue} <- ensure_queue(plan, token),
           {:ok, dirty_node_id} <- commit_dirty_tree(plan, queue, inserted.tip_node_id),
           :ok <- wake_sync(plan.project_id, inserted.tip_node_id) do
        {:ok,
         %{
           imported: inserted.imported,
           reused: inserted.reused,
           objects: copy.objects,
           bytes: copy.bytes,
           tip_node_id: inserted.tip_node_id,
           dirty_node_id: dirty_node_id
         }}
      end
    after
      Watcher.resume(plan.project_id, token)
    end
  end

  ## GenServer

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:enqueue, attrs, source}, _from, state) do
    case enqueue_job(attrs, source, state) do
      {:ok, job, state} ->
        {state, _job} = maybe_start(state)
        {:reply, {:ok, public_job(job)}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:status, job_id}, _from, state) do
    reply =
      case Map.fetch(state.jobs, job_id) do
        {:ok, job} -> {:ok, public_job(job)}
        :error -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call(:list, _from, state) do
    jobs = state.order |> Enum.map(&Map.get(state.jobs, &1)) |> Enum.reject(&is_nil/1)
    {:reply, Enum.map(jobs, &public_job/1), state}
  end

  @impl true
  def handle_info({ref, result}, %{running: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = finish_job(state, result)
    {state, _job} = maybe_start(state)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running: %{ref: ref}} = state) do
    state = finish_job(state, {:error, {:exited, reason}})
    {state, _job} = maybe_start(state)
    {:noreply, state}
  end

  def handle_info({:import_progress, job_id, update}, state) do
    jobs =
      case Map.fetch(state.jobs, job_id) do
        {:ok, job} -> Map.put(state.jobs, job_id, merge_progress(job, update))
        :error -> state.jobs
      end

    {:noreply, %{state | jobs: jobs}}
  end

  def handle_info({:import_timeout, ref}, %{running: %{ref: ref} = running} = state) do
    # The task may have finished just as the timer fired; its result wins over
    # the deadline (and is already in this mailbox if it was sent).
    receive do
      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        state = finish_job(state, result)
        {state, _job} = maybe_start(state)
        {:noreply, state}
    after
      0 ->
        Process.demonitor(ref, [:flush])

        if is_pid(running.pid) and Process.alive?(running.pid) do
          Process.exit(running.pid, :kill)
        end

        job = state.jobs[running.job_id]
        Logger.warning("import job #{running.job_id} exceeded its time bound and was stopped")

        # A killed task never runs its `after`, so release the watcher here.
        if job, do: Watcher.resume(job.project_id, suspension_token(job.id))

        state = finish_job(state, {:error, :timeout})
        {state, _job} = maybe_start(state)
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  ## Validation and planning

  defp normalize_attrs(attrs) do
    Map.new(attrs, fn {key, value} ->
      case key do
        k when is_atom(k) -> {Atom.to_string(k), value}
        k -> {k, value}
      end
    end)
  end

  defp safe_prepare(attrs) do
    prepare(attrs)
  rescue
    exception ->
      Logger.warning("import validation failed: #{Exception.message(exception)}")
      {:error, {:invalid_source, :unreadable_object}}
  catch
    kind, reason ->
      Logger.warning("import validation failed: #{inspect({kind, reason})}")
      {:error, {:invalid_source, :unreadable_object}}
  end

  defp prepare(attrs) do
    with {:ok, work_dir} <- fetch_work_dir(attrs),
         {:ok, refs} <- fetch_refs(attrs),
         {:ok, all_refs?} <- fetch_bool(attrs, "all_refs"),
         {:ok, allow_shallow?} <- fetch_bool(attrs, "allow_shallow", Env.import_allow_shallow?()),
         {:ok, limit} <- fetch_limit(attrs),
         {:ok, name} <- fetch_optional_string(attrs, "name"),
         {:ok, slug} <- fetch_optional_string(attrs, "slug"),
         :ok <- ensure_directory(work_dir),
         {:ok, repo} <- GitStore.detect_repository(work_dir),
         git = GitStore.open(repo.git_dir, bare: true),
         {:ok, selected} <- select_refs(git, refs, all_refs?),
         {:ok, walk} <- walk_commits(git, selected, limit),
         :ok <- check_shallow(walk, allow_shallow?),
         {:ok, preflight} <- preflight(git, walk.commits) do
      tips = selected |> Enum.map(& &1.sha) |> Enum.uniq()
      merge_commits = Enum.count(walk.commits, &(length(&1.parent) > 1))

      {:ok,
       %{
         path: work_dir,
         kind: repo.kind,
         git_dir: repo.git_dir,
         git: git,
         refs: selected,
         tips: tips,
         tip: hd(tips),
         commits: walk.commits,
         shallow: walk.shallow,
         merge_commits: merge_commits,
         preflight: preflight,
         name: name,
         slug: slug
       }}
    end
  end

  defp fetch_work_dir(attrs) do
    case attrs["work_dir"] do
      dir when is_binary(dir) and dir != "" -> {:ok, Path.expand(dir)}
      _other -> {:error, :missing_work_dir}
    end
  end

  defp fetch_refs(attrs) do
    case attrs["refs"] do
      nil ->
        {:ok, []}

      refs when is_list(refs) ->
        if Enum.all?(refs, &(is_binary(&1) and &1 != "")) do
          {:ok, refs}
        else
          {:error, :invalid_refs}
        end

      _other ->
        {:error, :invalid_refs}
    end
  end

  defp fetch_bool(attrs, key, default \\ false) do
    case Map.get(attrs, key) do
      nil -> {:ok, default}
      true -> {:ok, true}
      false -> {:ok, false}
      _other -> {:error, :invalid_payload}
    end
  end

  defp fetch_limit(attrs) do
    case attrs["limit"] do
      nil -> {:ok, nil}
      limit when is_integer(limit) and limit > 0 -> {:ok, limit}
      _other -> {:error, :invalid_limit}
    end
  end

  defp fetch_optional_string(attrs, key) do
    case Map.get(attrs, key) do
      nil -> {:ok, nil}
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :invalid_payload}
    end
  end

  defp ensure_directory(path) do
    if File.dir?(path), do: :ok, else: {:error, :not_a_directory}
  end

  defp select_refs(git, explicit, all_refs?) do
    requested =
      cond do
        explicit != [] -> explicit
        true -> ["HEAD"]
      end

    requested =
      if all_refs? do
        {:ok, listed} = GitStore.list_refs(git)
        requested ++ ["HEAD" | Enum.map(listed, & &1.name)]
      else
        requested
      end

    resolved = resolve_refs(git, Enum.uniq(requested))

    case resolved do
      {:ok, refs} -> dedupe_refs(refs)
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_refs(git, refs) do
    refs
    |> Enum.reduce_while({:ok, []}, fn ref, {:ok, acc} ->
      case GitStore.resolve_revision(git, ref) do
        {:ok, sha} ->
          {:cont, {:ok, [%{name: display_ref(git, ref), sha: sha} | acc]}}

        {:error, :not_found} ->
          {:halt, {:error, {:ref_not_found, ref}}}

        {:error, :not_a_commit} ->
          {:halt, {:error, {:not_a_commit, ref}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, :no_refs}
      {:ok, refs} -> {:ok, Enum.reverse(refs)}
      {:error, reason} -> {:error, reason}
    end
  end

  # A symbolic HEAD is reported under its branch name; a detached HEAD keeps
  # "HEAD". With `--all-refs` the branch entry already carries the same commit,
  # so drop the redundant HEAD row.
  defp display_ref(git, "HEAD") do
    case File.read(Path.join(git.home_dir, "HEAD")) do
      {:ok, contents} ->
        case String.trim(contents) do
          "ref:" <> target -> String.trim(target)
          _sha -> "HEAD"
        end

      _error ->
        "HEAD"
    end
  end

  defp display_ref(_git, ref), do: ref

  defp dedupe_refs(refs) do
    refs
    |> Enum.uniq_by(&{&1.name, &1.sha})
    |> drop_covered_head()
  end

  defp drop_covered_head(refs) do
    covered =
      refs
      |> Enum.reject(&(&1.name == "HEAD"))
      |> MapSet.new(& &1.sha)

    {:ok, Enum.reject(refs, &(&1.name == "HEAD" and MapSet.member?(covered, &1.sha)))}
  end

  defp walk_commits(git, refs, limit) do
    tips = refs |> Enum.map(& &1.sha) |> Enum.uniq()
    max = effective_limit(limit)

    case GitStore.walk_commits(git, tips, max: max, truncate: false) do
      {:ok, walk} ->
        {:ok, walk}

      {:error, {:too_many_commits, cap}} ->
        {:error, {:too_many_commits, cap}}

      {:error, {:missing_object, sha}} ->
        {:error, {:missing_object, sha}}

      {:error, :invalid_tips} ->
        {:error, :no_refs}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp effective_limit(nil), do: Env.import_max_commits()
  defp effective_limit(limit), do: min(limit, Env.import_max_commits())

  defp check_shallow(%{shallow: true}, false), do: {:error, :shallow_repository}
  defp check_shallow(_walk, _allow?), do: :ok

  defp preflight(git, commits) do
    GitStore.preflight_blobs(git, commits, max_blob_bytes: Env.import_max_blob_bytes())
  end

  ## Project resolution and enqueue

  defp enqueue_job(attrs, source, state) do
    with :ok <- check_capacity(state),
         :ok <- check_active_path(state, source.path),
         {:ok, project, location} <- resolve_project(attrs, source),
         :ok <- ensure_importable(project.id) do
      job = new_job(project, location, source)
      {:ok, public_job(job), add_job(state, job)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_capacity(state) do
    pending =
      state.jobs
      |> Map.values()
      |> Enum.count(&(&1.status in [:queued, :running]))

    if pending >= @max_pending, do: {:error, :too_many_jobs}, else: :ok
  end

  defp check_active_path(state, path) do
    active? =
      state.jobs
      |> Map.values()
      |> Enum.any?(fn job ->
        job.status in [:queued, :running] and Path.expand(job.source.path) == path
      end)

    if active?, do: {:error, :import_in_progress}, else: :ok
  end

  defp resolve_project(%{"project_id" => project_id}, source) when is_binary(project_id) do
    resolve_by_id(project_id, source)
  end

  defp resolve_project(%{"project_id" => _invalid}, _source), do: {:error, :invalid_project}

  defp resolve_project(_attrs, source), do: resolve_by_location(source)

  defp resolve_by_id(project_id, source) do
    with {:ok, project_id} <- cast_project_id(project_id),
         {:ok, project} <- fetch_project(project_id),
         {:ok, location} <- fetch_location(project_id),
         :ok <- same_source?(location, source) do
      {:ok, project, location}
    end
  end

  defp resolve_by_location(source) do
    case Repo.get_by(ProjectLocation, work_dir: source.path) do
      %ProjectLocation{} = location ->
        case fetch_project(location.project_id) do
          {:ok, project} -> {:ok, project, location}
          {:error, reason} -> {:error, reason}
        end

      nil ->
        register_import_project(source)
    end
  end

  defp cast_project_id(project_id) do
    case UUID.cast(project_id) do
      {:ok, project_id} -> {:ok, project_id}
      :error -> {:error, :invalid_project}
    end
  end

  defp fetch_project(project_id) do
    case Repo.get(Project, project_id) do
      %Project{} = project -> {:ok, project}
      nil -> {:error, :project_not_found}
    end
  end

  defp fetch_location(project_id) do
    case Repo.get(ProjectLocation, project_id) do
      %ProjectLocation{} = location -> {:ok, location}
      nil -> {:error, :project_location_mismatch}
    end
  end

  defp same_source?(%ProjectLocation{work_dir: work_dir}, %{path: path}) do
    if Path.expand(work_dir) == Path.expand(path),
      do: :ok,
      else: {:error, :project_location_mismatch}
  end

  defp register_import_project(source) do
    name = source.name || Path.basename(source.path)
    slug = source.slug || slugify(name)

    attrs = %{"name" => name, "slug" => slug, "work_dir" => source.path}

    case Projects.register_project(attrs, watch: false) do
      {:ok, project} ->
        {:ok, project, Repo.get!(ProjectLocation, project.id)}

      {:error, :already_registered} ->
        # A concurrent submit won the race; adopt the project it created.
        case Repo.get_by(ProjectLocation, work_dir: source.path) do
          %ProjectLocation{} = location ->
            with {:ok, project} <- fetch_project(location.project_id) do
              {:ok, project, location}
            end

          nil ->
            {:error, :already_registered}
        end

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, {:invalid_project, changeset_errors(changeset)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp slugify(name) do
    slug =
      name
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    if slug == "", do: "import", else: slug
  end

  defp ensure_importable(project_id) do
    metadata =
      Repo.all(
        from(n in Node,
          where: n.project_id == ^project_id,
          select: n.session_metadata
        )
      )

    cond do
      metadata == [] -> :ok
      Enum.any?(metadata, &imported_metadata?/1) -> :ok
      true -> {:error, :project_not_importable}
    end
  end

  defp imported_metadata?(%{"import" => %{"source" => "git"}}), do: true
  defp imported_metadata?(_metadata), do: false

  defp new_job(project, location, source) do
    job_id = Ecto.UUID.generate()

    plan =
      source
      |> Map.put(:job_id, job_id)
      |> Map.put(:project_id, project.id)
      |> Map.put(:project_slug, project.slug)
      |> Map.put(:git_dir, location.git_dir)
      |> Map.put(:push_batch, Env.import_push_batch())

    %{
      id: job_id,
      project_id: project.id,
      project_slug: project.slug,
      source: %{path: source.path, kind: Atom.to_string(source.kind)},
      refs: Enum.map(source.refs, & &1.name),
      tips: source.tips,
      tip: source.tip,
      total: length(source.commits),
      merge_commits: source.merge_commits,
      imported: 0,
      reused: 0,
      objects: 0,
      bytes: 0,
      largest_node_bytes: source.preflight.largest_node_bytes,
      shallow: source.shallow,
      status: :queued,
      error: nil,
      created_at: DateTime.utc_now(),
      started_at: nil,
      finished_at: nil,
      tip_node_id: nil,
      dirty_node_id: nil,
      plan: plan
    }
  end

  defp public_job(job), do: Map.delete(job, :plan)

  defp add_job(state, job) do
    order = [job.id | state.order]
    {order, jobs} = prune_jobs(order, Map.put(state.jobs, job.id, job))
    %{state | jobs: jobs, order: order, queue: :queue.in(job.id, state.queue)}
  end

  defp prune_jobs(order, jobs) do
    {active, terminal} = Enum.split_with(order, &active_job?(Map.get(jobs, &1)))

    kept = MapSet.new(active ++ Enum.take(terminal, @keep_jobs))

    {
      Enum.filter(order, &MapSet.member?(kept, &1)),
      Map.take(jobs, MapSet.to_list(kept))
    }
  end

  defp active_job?(%{status: status}), do: status in [:queued, :running]
  defp active_job?(_job), do: false

  ## Job execution

  defp maybe_start(%{running: nil} = state) do
    case :queue.out(state.queue) do
      {:empty, _queue} ->
        {state, nil}

      {{:value, job_id}, queue} ->
        case Map.fetch(state.jobs, job_id) do
          {:ok, job} ->
            importer = self()
            progress = fn update -> send(importer, {:import_progress, job_id, update}) end
            runner = runner()
            plan = job.plan

            task =
              Task.Supervisor.async_nolink(Cadence.Daemon.ImportTasks, fn ->
                run_safely(runner, plan, progress)
              end)

            timer = start_timer(task.ref)
            job = %{job | status: :running, started_at: DateTime.utc_now()}

            running = %{job_id: job.id, ref: task.ref, pid: task.pid, timer: timer}

            {%{state | queue: queue, jobs: Map.put(state.jobs, job.id, job), running: running},
             job}

          :error ->
            maybe_start(%{state | queue: queue})
        end
    end
  end

  defp maybe_start(state), do: {state, nil}

  defp runner do
    Application.get_env(:cadence_daemon, :import_runner, &__MODULE__.execute/2)
  end

  defp run_safely(runner, plan, progress) do
    runner.(plan, progress)
  rescue
    exception -> {:error, {:exception, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp start_timer(ref) do
    case Env.import_max_seconds() do
      0 -> nil
      seconds -> Process.send_after(self(), {:import_timeout, ref}, seconds * 1_000)
    end
  end

  defp finish_job(state, result) do
    running = state.running

    if is_nil(running) do
      state
    else
      if running.timer, do: Process.cancel_timer(running.timer)

      case Map.fetch(state.jobs, running.job_id) do
        {:ok, job} ->
          job =
            case result do
              {:ok, summary} ->
                job
                |> Map.merge(Map.take(summary, [:imported, :reused, :objects, :bytes]))
                |> Map.put(:tip_node_id, Map.get(summary, :tip_node_id))
                |> Map.put(:dirty_node_id, Map.get(summary, :dirty_node_id))
                |> Map.put(:status, :completed)
                |> Map.put(:finished_at, DateTime.utc_now())

              {:error, reason} ->
                %{
                  job
                  | status: :failed,
                    error: format_error(reason),
                    finished_at: DateTime.utc_now()
                }

              other ->
                %{
                  job
                  | status: :failed,
                    error: format_error({:unexpected, other}),
                    finished_at: DateTime.utc_now()
                }
            end

          # A terminal job is never resumed from memory (a resubmit re-walks),
          # so do not retain its commit maps and source handle.
          job = Map.delete(job, :plan)
          %{state | jobs: Map.put(state.jobs, job.id, job), running: nil}

        :error ->
          %{state | running: nil}
      end
    end
  end

  defp merge_progress(job, update) do
    job
    |> Map.merge(Map.take(update, [:imported, :reused, :objects, :bytes]))
  end

  defp copy_objects(plan, target) do
    case GitStore.copy_commit_objects(plan.git, target, plan.commits,
           max_blob_bytes: Env.import_max_blob_bytes()
         ) do
      {:ok, summary} -> {:ok, summary}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_nodes(plan, progress) do
    existing =
      Repo.all(
        from(n in Node,
          where: n.project_id == ^plan.project_id,
          select: {n.git_commit_sha, n.id}
        )
      )
      |> Map.new()

    shallow = GitStore.shallow_commits(plan.git)
    imported_at = DateTime.utc_now()
    refs = Enum.map(plan.refs, & &1.name)

    plan.commits
    |> Enum.chunk_every(plan.push_batch)
    |> Enum.reduce_while({:ok, existing, %{imported: 0, reused: 0}}, fn batch,
                                                                        {:ok, map, counts} ->
      case insert_batch(batch, map, plan, refs, imported_at, shallow) do
        {:ok, map, inserted, reused} ->
          counts = %{
            imported: counts.imported + inserted,
            reused: counts.reused + reused
          }

          report(progress, counts)
          {:cont, {:ok, map, counts}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, map, counts} ->
        tip_node_id = Map.fetch!(map, plan.tip)
        {:ok, Map.put(counts, :tip_node_id, tip_node_id)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp insert_batch(batch, map, plan, refs, imported_at, shallow) do
    result =
      Repo.transaction(fn ->
        Enum.reduce(batch, {map, 0, 0}, fn commit, {map, imported, reused} ->
          case Map.get(map, commit.hash) do
            nil ->
              with {:ok, node} <-
                     insert_node(commit, map, plan, refs, imported_at, shallow) do
                SyncLedger.insert_pending!(node)
                {Map.put(map, commit.hash, node.id), imported + 1, reused}
              else
                {:error, reason} -> Repo.rollback(reason)
              end

            _node_id ->
              {map, imported, reused + 1}
          end
        end)
      end)

    case result do
      {:ok, {map, imported, reused}} -> {:ok, map, imported, reused}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_node(commit, map, plan, refs, imported_at, shallow) do
    with {:ok, parents} <- parent_ids(commit, map, shallow) do
      attrs = %{
        project_id: plan.project_id,
        git_commit_sha: commit.hash,
        parents: parents,
        flags: [:imported],
        pinned: commit.hash == plan.tip,
        message: commit_message(commit),
        session_metadata: %{
          "import" => import_metadata(commit, plan, refs, imported_at)
        },
        created_by: Env.local_user_id(),
        created_at: commit_time(commit),
        docs_state: :skipped
      }

      case attrs |> Node.changeset() |> Repo.insert() do
        {:ok, node} ->
          {:ok, node}

        {:error, changeset} ->
          {:error, {:invalid_node, changeset_errors(changeset)}}
      end
    end
  end

  defp parent_ids(commit, map, shallow) do
    commit.parent
    |> Enum.reduce_while({:ok, []}, fn parent_sha, {:ok, acc} ->
      case Map.fetch(map, parent_sha) do
        {:ok, node_id} ->
          {:cont, {:ok, [node_id | acc]}}

        :error ->
          if MapSet.member?(shallow, commit.hash) do
            {:cont, {:ok, acc}}
          else
            {:halt, {:error, {:missing_parent, parent_sha}}}
          end
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp import_metadata(commit, plan, refs, imported_at) do
    {name, email} = commit_author(commit)

    metadata = %{
      "source" => "git",
      "author" => name,
      "author_email" => email,
      "imported_at" => DateTime.to_iso8601(imported_at)
    }

    if commit.hash in plan.tips, do: Map.put(metadata, "refs", refs), else: metadata
  end

  defp commit_author(commit) do
    identity = commit.author || commit.committer || %{}

    {
      Map.get(identity, :name, ""),
      Map.get(identity, :email, "")
    }
  end

  defp commit_message(commit) do
    message =
      commit.message
      |> to_string()
      |> String.trim_trailing()

    # Older histories can carry latin-1 or otherwise invalid bytes; Jason and
    # the UI require valid UTF-8.
    if String.valid?(message), do: message, else: String.replace_invalid(message)
  end

  defp commit_time(commit) do
    identity = commit.author || commit.committer

    case identity do
      %{timestamp: timestamp} when is_integer(timestamp) and timestamp >= 0 ->
        DateTime.from_unix!(timestamp, :second)

      _other ->
        DateTime.utc_now()
    end
  rescue
    _exception -> DateTime.utc_now()
  end

  defp point_at_tip(project_id, tip_node_id) do
    # A project adopted by location may predate this daemon's membership row.
    Session.ensure_membership!(project_id)

    case Session.current_node(project_id) do
      %Node{id: ^tip_node_id} ->
        :ok

      nil ->
        move_pointer(project_id, tip_node_id)

      %Node{} = current ->
        # A local commit (for example the dirty-tree node, or work made after an
        # earlier import) is newer than the selected ref; never rewind the user
        # to the imported tip.
        if imported_node?(current), do: move_pointer(project_id, tip_node_id), else: :ok
    end
  end

  defp move_pointer(project_id, tip_node_id) do
    case Session.switch(project_id, tip_node_id) do
      {:ok, _membership} -> :ok
      {:error, _reason} -> {:error, :pointer_failed}
    end
  end

  defp imported_node?(%Node{session_metadata: %{"import" => %{"source" => "git"}}}), do: true
  defp imported_node?(_node), do: false

  defp ensure_queue(%{kind: :bare}, _token), do: {:ok, nil}

  defp ensure_queue(plan, token) do
    case ProjectRegistry.lookup_queue(plan.project_id) do
      nil ->
        case ProjectRegistry.start_project(
               project_id: plan.project_id,
               work_dir: plan.path,
               git_dir: plan.git_dir
             ) do
          {:ok, _pid} ->
            Watcher.suspend(plan.project_id, token)
            {:ok, ProjectRegistry.lookup_queue(plan.project_id)}

          {:error, {:already_started, _pid}} ->
            queue = ProjectRegistry.lookup_queue(plan.project_id)
            if queue, do: Watcher.suspend(plan.project_id, token)
            {:ok, queue}

          {:error, _reason} ->
            {:error, :project_unavailable}
        end

      queue ->
        # A `:transient` supervisor is restarted only while the project is
        # healthy; a stale registry entry without a live pid is still a failure.
        Watcher.suspend(plan.project_id, token)
        {:ok, queue}
    end
  end

  defp commit_dirty_tree(_plan, nil, _tip_node_id), do: {:ok, nil}

  defp commit_dirty_tree(plan, queue, tip_node_id) do
    current_id =
      case Session.current_node(plan.project_id) do
        %Node{id: id} -> id
        nil -> nil
      end

    case CommitQueue.commit(queue, @default_message, skip_unchanged: true) do
      {:ok, nil} -> {:ok, nil}
      {:ok, %Node{id: id}} when id == tip_node_id or id == current_id -> {:ok, nil}
      {:ok, %Node{id: id}} -> {:ok, id}
      {:error, _reason} -> {:error, :dirty_commit_failed}
    end
  end

  defp wake_sync(_project_id, nil), do: :ok

  defp wake_sync(project_id, tip_node_id) do
    SyncLedger.enqueue(project_id, tip_node_id)
    :ok
  end

  defp report(progress, update) do
    progress.(update)
    :ok
  end

  ## Helpers

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp suspension_token(job_id), do: {:import, job_id}

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp format_error(reason) do
    case reason do
      :timeout ->
        %{code: "timeout", message: "the import exceeded its time bound"}

      :shallow_repository ->
        %{code: "shallow_repository", message: "source is a shallow clone"}

      :project_unavailable ->
        %{code: "project_unavailable", message: "project queue unavailable"}

      :pointer_failed ->
        %{code: "pointer_failed", message: "could not move the session pointer"}

      :dirty_commit_failed ->
        %{code: "dirty_commit_failed", message: "could not commit local changes"}

      {:too_many_commits, max} ->
        %{code: "too_many_commits", message: "history exceeds #{max} commits", max: max}

      {:blob_too_large, path, size} ->
        %{
          code: "blob_too_large",
          message: "blob #{path} is #{size} bytes",
          path: path,
          size: size
        }

      {:missing_object, sha} ->
        %{code: "missing_object", message: "missing Git object #{sha}", sha: sha}

      {:missing_parent, sha} ->
        %{code: "missing_parent", message: "missing parent commit #{sha}", sha: sha}

      {:invalid_node, errors} ->
        %{code: "invalid_node", message: "invalid imported node", details: inspect(errors)}

      {:exception, message} ->
        %{code: "exception", message: message}

      {kind, value} when is_atom(kind) ->
        %{code: Atom.to_string(kind), message: inspect(value, limit: 20, printable_limit: 500)}

      other ->
        %{code: "error", message: inspect(other, limit: 20, printable_limit: 500)}
    end
  end
end
