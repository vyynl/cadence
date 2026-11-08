defmodule Cadence.Server.Actions.Runs do
  @moduledoc """
  Durable execution of manifest actions against an immutable node snapshot
  (spec §8).

  ## Flow

  1. `prepare/4` re-checks the run boundary — enabled deployment, project and
     node, manager membership, open critical incident — and snaps the action's
     command into a `:queued` run row.
  2. `start/4` calls `dispatch/1`, which claims the project's oldest queued run
     when a concurrency slot is free and submits `execute_claimed/1` to
     `Cadence.Server.Actions.TaskSupervisor`.
  3. `execute/1` moves the row to `:running` (the claim already did for a
     dispatched run), stages the snapshot (one bounded walk that also re-runs
     the content quarantine check), resolves the image, creates and starts the
     container, waits for exit, captures the log, copies artifacts, and records
     a terminal status.

  Every failure after `prepare/4` is a terminal run status with a shape-only
  `error_reason`; container output only ever reaches the artifact directory.

  ## Queue and concurrency

  `:queued` is waiting work, not staleness. At most
  `CAD_ACTIONS_MAX_CONCURRENT_RUNS` runs per project may be `:running` (`0`
  disables the cap). A claim is one transaction: a per-project
  `pg_try_advisory_xact_lock` serializes claimers across processes and server
  nodes, the running count is read, and the oldest queued row is
  compare-and-set to `:running`. The spawned task then executes it.

  Dispatch happens on `start/4`, after every committed terminal transition, and
  once at boot (`Cadence.Server.Actions.Dispatcher`); each is best-effort. A
  task that cannot be started fails its row (`run_failed`) and the next queued
  run is dispatched.

  ## Durability

  A run row is written before any container exists. If the server dies mid-run,
  the row stays `:running`; `recover_stale/1` marks such rows `:interrupted`
  once they are older than the build + run budgets. Queued rows are never
  interrupted: they are resumed by the boot dispatch or the next terminal
  transition.

  ## Broadcasting

  `{:action_run_updated, project_id, run_id, status}` fires on `project:<id>`
  after each committed status change. Broadcasting is best-effort and carries
  ids only — never logs or commands.
  """

  import Ecto.Query

  require Logger

  alias Cadence.Server.{
    ActionRun,
    Authorization,
    Incidents,
    Portfolio,
    ProjectGit,
    PublicContent,
    Repo
  }

  alias Cadence.Server.Actions
  alias Cadence.Server.Actions.{Artifacts, Docker, Staging, TaskSupervisor}
  alias Cadence.Shared.{Node, Project, UUID}

  @allowed_transitions %{
    queued: [:running, :failed, :interrupted],
    running: [:succeeded, :failed, :timed_out, :interrupted]
  }

  @terminal_statuses [:succeeded, :failed, :timed_out, :interrupted]

  @default_list_limit 50
  @stale_margin_ms 60_000

  # Two-int form so a project id never has to fit in an int4; `hashtext` is
  # evaluated by the database that holds the lock (multi-node safe). Scoped to
  # action-run claims, so it never contends with proposal decisions, which lock
  # the project row.
  @claim_lock_sql "SELECT pg_try_advisory_xact_lock(hashtext('cadence.action_runs'), hashtext($1))"

  @type error ::
          :disabled
          | :forbidden
          | :not_found
          | :quarantined
          | :unknown_action
          | Ecto.Changeset.t()

  @doc """
  Validate a run request and insert a `:queued` row.

  Members may list actions (6a); only owner/trusted may run one. The open
  incident check is cheap and catches the mutable quarantine case; the content
  scan runs during staging, which keeps the store walk single for the normal
  flow. The UI reuses its rendered scan on a click and only re-derives it in raw
  view, where that answer was deliberately bypassed.
  """
  @spec prepare(map(), String.t(), String.t(), String.t()) ::
          {:ok, ActionRun.t()} | {:error, error()}
  def prepare(actor, project_id, node_id, action_name) do
    with :ok <- check_enabled(),
         {:ok, project_id} <- uuid(project_id),
         {:ok, node_id} <- uuid(node_id),
         # Authorization first: a non-member must not learn whether the project
         # or node exists, and must not reach any write path.
         {:ok, membership} <- authorize_manager(actor, project_id),
         {:ok, project} <- fetch_project(project_id),
         {:ok, node} <- fetch_node(project_id, node_id),
         :ok <- check_quarantine(project, node),
         {:ok, action} <- fetch_action(project, node, membership, action_name) do
      insert_run(project, node, actor, action)
    end
  end

  @doc """
  `prepare/4` plus a dispatch attempt.

  Returns as soon as the run row exists. The row starts only if a concurrency
  slot is free; otherwise it stays `:queued` and starts when a slot frees (or at
  boot). The caller (6c) follows progress on the project PubSub topic.

  A dispatch is FIFO: this call may start an older queued run before the one it
  just wrote. If the execution task cannot be started, that row is failed
  (`run_failed`) and the next queued run is dispatched, so `{:ok, run}` can
  refer to a row that has already failed; the run page shows the real state.
  """
  @spec start(map(), String.t(), String.t(), String.t()) ::
          {:ok, ActionRun.t()} | {:error, error()}
  def start(actor, project_id, node_id, action_name) do
    with {:ok, run} <- prepare(actor, project_id, node_id, action_name) do
      :ok = dispatch(run.project_id)
      {:ok, run}
    end
  end

  @doc """
  Execute a queued run synchronously (tests and ops call it directly).

  This path bypasses the per-project cap; user submissions go through
  `start/4` → `dispatch/1`. Idempotent against a stale row: if another process
  already moved the status, the transition compare-and-set fails and this
  returns `{:error, :stale}`.
  """
  @spec execute(ActionRun.t()) :: {:ok, ActionRun.t()} | {:error, :stale}
  def execute(%ActionRun{} = run) do
    case transition(run, :running, %{started_at: now()}) do
      {:ok, running} ->
        execute_claimed(running)

      {:error, :stale} ->
        {:error, :stale}
    end
  end

  # The row was already claimed to :running by `dispatch/1` (or by `execute/1`).
  defp execute_claimed(%ActionRun{status: :running} = running) do
    case {fetch_project(running.project_id), fetch_node(running.project_id, running.node_id)} do
      {{:ok, project}, {:ok, node}} ->
        run_pipeline(running, project, node)

      _other ->
        # The row is already :running; finish against the running struct so the
        # CAS matches instead of leaving a phantom running row.
        finish_failure(running, "run_failed")
    end
  end

  @doc """
  Claim and start queued runs for `project_id` up to the per-project cap.

  Best-effort: every failure is logged by shape and returns `:ok`. Safe to call
  from any process and from more than one server node: a per-project
  transaction-scoped advisory lock serializes claimers, and the running count is
  read under it.

  Recovery runs first with `remove_containers: false` (a DB-only write), so a
  dead `:running` row cannot hold a slot without blocking the caller on Docker.
  """
  @spec dispatch(String.t()) :: :ok
  def dispatch(project_id) when is_binary(project_id) do
    if Actions.enabled?() do
      _ = recover_stale(project_id, remove_containers: false)
      claim_until_full(project_id)
    end

    :ok
  rescue
    error ->
      Logger.warning("action run dispatch skipped: #{shape(error)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("action run dispatch exited: #{inspect(kind)}/#{shape(reason)}")
      :ok
  end

  def dispatch(_project_id), do: :ok

  @doc """
  Dispatch every project that has a queued run (boot/ops; never routed).

  Best-effort like `dispatch/1`; used by `Actions.Dispatcher` and recovery
  tooling.
  """
  @spec dispatch_all() :: :ok
  def dispatch_all do
    if Actions.enabled?() do
      from(r in ActionRun, where: r.status == :queued, distinct: true, select: r.project_id)
      |> Repo.all()
      |> Enum.each(&dispatch/1)
    end

    :ok
  rescue
    error ->
      Logger.warning("action run dispatch (all) skipped: #{shape(error)}")
      :ok
  end

  defp claim_until_full(project_id) do
    case claim_next(project_id) do
      {:ok, nil} ->
        :ok

      {:ok, run} ->
        broadcast(run)
        spawn_claimed(run)
        claim_until_full(project_id)

      {:error, reason} ->
        Logger.warning("action run claim skipped: #{shape(reason)}")
        :ok
    end
  end

  # One short transaction per slot: the advisory lock serializes claimers, so
  # the running count and the queued→running CAS cannot race another claim.
  defp claim_next(project_id) do
    Repo.transaction(fn ->
      if claim_lock(project_id) do
        if capacity?(project_id), do: claim_oldest(project_id), else: nil
      else
        nil
      end
    end)
  end

  defp claim_lock(project_id) do
    case Repo.query!(@claim_lock_sql, [project_id]) do
      %{rows: [[true]]} -> true
      _other -> false
    end
  end

  defp capacity?(project_id) do
    case Actions.max_concurrent_runs() do
      0 -> true
      cap -> running_count(project_id) < cap
    end
  end

  defp running_count(project_id) do
    Repo.one(
      from(r in ActionRun,
        where: r.project_id == ^project_id and r.status == :running,
        select: count(r.id)
      )
    )
  end

  defp claim_oldest(project_id) do
    case Repo.one(
           from(r in ActionRun,
             where: r.project_id == ^project_id and r.status == :queued,
             order_by: [asc: r.created_at, asc: r.id],
             limit: 1
           )
         ) do
      nil ->
        nil

      run ->
        timestamp = now()

        {count, _rows} =
          from(r in ActionRun, where: r.id == ^run.id and r.status == :queued)
          |> Repo.update_all(
            set: [status: :running, started_at: timestamp, updated_at: timestamp]
          )

        if count == 1, do: Repo.get!(ActionRun, run.id), else: nil
    end
  end

  defp spawn_claimed(run) do
    # A missing supervisor exits the caller rather than returning an error, so
    # the exit is caught here instead of crashing a manager's request.
    result =
      try do
        Task.Supervisor.start_child(task_supervisor(), fn ->
          # Container removal belongs off the caller's process. The claimed row
          # is fresh, so it is never selected as stale.
          _ = recover_stale(run.project_id)
          execute_claimed(run)
        end)
      catch
        :exit, reason -> {:error, reason}
      end

    case result do
      {:ok, _pid} ->
        :ok

      {:ok, _pid, _info} ->
        :ok

      {:error, reason} ->
        Logger.warning("action run task did not start: #{shape(reason)}")
        _ = finish_failure(run, "run_failed")
        :ok
    end
  end

  @doc """
  A project's runs, newest first (member-scoped; used by 6c).

  Returns `{:error, :disabled}` when the action layer is off for this
  deployment, matching the run boundary.
  """
  @spec list(map(), String.t(), keyword()) ::
          {:ok, [ActionRun.t()]} | {:error, :not_found | :forbidden | :disabled}
  def list(actor, project_id, opts \\ []) do
    with :ok <- check_enabled(),
         {:ok, project_id} <- uuid(project_id),
         {:ok, _membership} <- authorize_viewer(actor, project_id) do
      # Keep a read page honest without blocking it on the Docker proxy: mark
      # abandoned rows here, leave container removal to a manager-triggered
      # recovery or recover_all/0.
      _ = recover_stale(project_id, remove_containers: false)
      limit = opts |> Keyword.get(:limit, @default_list_limit) |> clamp_limit()

      {:ok,
       Repo.all(
         from(r in ActionRun,
           where: r.project_id == ^project_id,
           order_by: [desc: r.created_at, desc: r.id],
           limit: ^limit
         )
       )}
    end
  end

  @doc """
  One run, scoped to a project and a member (used by 6c).

  Returns `{:error, :disabled}` when the action layer is off for this
  deployment.
  """
  @spec get(map(), String.t(), String.t()) ::
          {:ok, ActionRun.t()} | {:error, :not_found | :forbidden | :disabled}
  def get(actor, project_id, run_id) do
    with :ok <- check_enabled(),
         {:ok, project_id} <- uuid(project_id),
         {:ok, run_id} <- uuid(run_id),
         {:ok, _membership} <- authorize_viewer(actor, project_id) do
      _ = recover_stale(project_id, remove_containers: false)

      case Repo.get_by(ActionRun, id: run_id, project_id: project_id) do
        nil -> {:error, :not_found}
        run -> {:ok, run}
      end
    end
  end

  @doc """
  Read the captured log (nil when the run produced none).

  Only pass a run obtained from `get/3` (or a returned run struct from
  `prepare/4`/`execute/1`): this function trusts the row's relative path and
  does not re-authorize.
  """
  @spec log(ActionRun.t()) :: {:ok, binary()} | {:error, :not_found}
  def log(%ActionRun{log_path: nil}), do: {:error, :not_found}

  def log(%ActionRun{log_path: path}) do
    case File.read(Path.join(artifact_root(), path)) do
      {:ok, content} -> {:ok, content}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  @doc """
  List the artifacts collected for a run.

  As with `log/1`, pass only a run obtained from `get/3`; the row's relative
  path is trusted and membership is not re-checked.
  """
  @spec artifacts(ActionRun.t()) :: [%{path: String.t(), size: non_neg_integer()}]
  def artifacts(%ActionRun{artifact_path: nil}), do: []

  def artifacts(%ActionRun{artifact_path: path}) do
    Artifacts.list(Path.join(artifact_root(), path))
  end

  @doc """
  Resolve one collected artifact to an absolute path for download.

  Only an exact relative path already returned by `artifacts/1` is accepted, so
  a crafted path cannot escape the run directory or reach the staging volume.
  The resolved entry must still be a regular file (no symlink target).
  """
  @spec read_artifact(ActionRun.t(), String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def read_artifact(%ActionRun{artifact_path: nil}, _relative), do: {:error, :not_found}

  def read_artifact(%ActionRun{} = run, relative) when is_binary(relative) do
    if Enum.any?(artifacts(run), &(&1.path == relative)) do
      path = Path.join(Path.join(artifact_root(), run.artifact_path), relative)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular}} -> {:ok, path}
        _other -> {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  def read_artifact(_run, _relative), do: {:error, :not_found}

  @doc """
  Mark this project's abandoned `:running` rows `:interrupted`.

  A `:queued` row is waiting work, not abandoned, and is left for `dispatch/1`.
  "Abandoned" means older than the build + run budgets plus a margin; a live
  run refreshes `updated_at` after staging, image resolution, container
  creation, and exit, so a legitimate long build is not mistaken for a crash.

  Each row is marked with a compare-and-set that re-checks the cutoff, so a row
  that heartbeats or finishes between selection and update is left alone and no
  spurious broadcast fires. Container removal happens only when
  `:remove_containers` is true (the manager-triggered `start/4` path and
  `recover_all/0`): a read page must not block on the Docker proxy. With
  `remove_containers: false` the container id is kept, and the next
  manager-triggered recovery or `recover_all/0` sweeps interrupted rows.

  Ops/internal only: it writes run state and must never be exposed as a route.
  Best-effort; failures are logged by shape.
  """
  @spec recover_stale(String.t(), keyword()) :: :ok
  def recover_stale(project_id, opts \\ []) do
    with {:ok, project_id} <- uuid(project_id) do
      cutoff = DateTime.add(now(), -stale_after_ms(), :millisecond)
      remove? = Keyword.get(opts, :remove_containers, true)

      from(r in ActionRun,
        where: r.project_id == ^project_id and r.status == :running and r.updated_at < ^cutoff
      )
      |> stale_rows()
      |> recover_rows(cutoff, remove?)

      if remove?, do: sweep_project_orphans(project_id)
    end

    :ok
  rescue
    error ->
      Logger.warning("action run recovery skipped: #{shape(error)}")
      :ok
  end

  @doc "`recover_stale/1` for every project (ops/6c helper; never routed)."
  @spec recover_all() :: :ok
  def recover_all do
    cutoff = DateTime.add(now(), -stale_after_ms(), :millisecond)

    from(r in ActionRun, where: r.status == :running and r.updated_at < ^cutoff)
    |> stale_rows()
    |> recover_rows(cutoff, true)

    sweep_orphans(
      from(r in ActionRun,
        where: r.status in ^@terminal_statuses and not is_nil(r.container_id)
      )
    )

    :ok
  rescue
    error ->
      Logger.warning("action run recovery (all) skipped: #{shape(error)}")
      :ok
  end

  defp stale_rows(query) do
    Repo.all(
      from(r in query,
        select: %{id: r.id, project_id: r.project_id, container_id: r.container_id}
      )
    )
  end

  defp recover_rows(rows, cutoff, remove?) do
    Enum.each(rows, fn row -> recover_row(row, cutoff, remove?) end)
    :ok
  end

  defp recover_row(row, cutoff, remove?) do
    # CAS first, with the container id retained. Only the caller that actually
    # wins the transition may touch the container; a row that heartbeated or
    # finished between selection and update is left alone.
    {count, _rows} =
      from(r in ActionRun,
        where: r.id == ^row.id and r.status == :running and r.updated_at < ^cutoff
      )
      |> Repo.update_all(set: interrupted_set())

    if count == 1 do
      broadcast(row.project_id, row.id, :interrupted)

      if remove? and is_binary(row.container_id) and
           remove_container(row.container_id) == :ok do
        from(r in ActionRun, where: r.id == ^row.id)
        |> Repo.update_all(set: [container_id: nil])
      end
    end

    :ok
  end

  defp interrupted_set do
    [
      status: :interrupted,
      error_reason: "interrupted",
      updated_at: now(),
      finished_at: now()
    ]
  end

  defp sweep_project_orphans(project_id) do
    sweep_orphans(
      from(r in ActionRun,
        where:
          r.project_id == ^project_id and r.status in ^@terminal_statuses and
            not is_nil(r.container_id)
      )
    )
  end

  defp sweep_orphans(query) do
    Repo.all(
      from(r in query,
        select: %{id: r.id, project_id: r.project_id, container_id: r.container_id}
      )
    )
    |> Enum.each(fn row ->
      if remove_container(row.container_id) == :ok do
        from(r in ActionRun, where: r.id == ^row.id)
        |> Repo.update_all(set: [container_id: nil])
      end
    end)

    :ok
  end

  defp remove_container(nil), do: :ok

  defp remove_container(container_id) do
    Docker.impl().remove(container_id)
  rescue
    error ->
      Logger.warning("action container removal skipped: #{shape(error)}")
      {:error, :remove_failed}
  end

  ## Pipeline

  defp run_pipeline(run, project, node) do
    run_dir = run_dir(run)
    code_dir = Path.join(run_dir, "code")
    out_dir = Path.join(run_dir, "out")
    docker = Docker.impl()

    try do
      with :ok <- ensure_run_dir(run_dir, out_dir),
           {:ok, blobs} <- load_snapshot(project, node),
           :ok <- check_content(blobs),
           :ok <- touch(run),
           :ok <- write_snapshot(blobs, code_dir),
           {:ok, image} <- resolve_image(docker, project, node, code_dir, blobs),
           :ok <- touch(run),
           {:ok, container_id} <- create_container(docker, run, project, node, image) do
        await_and_collect(docker, run, container_id, out_dir, image)
      else
        {:error, reason} -> finish_failure(run, error_reason(reason))
      end
    rescue
      error ->
        # A corrupt store or an adapter exception must not leave the row
        # :running forever; log the shape only.
        Logger.warning("action run crashed: #{shape(error)}")
        finish_failure(run, "run_failed")
    catch
      kind, reason ->
        Logger.warning("action run exited: #{inspect(kind)}/#{shape(reason)}")
        finish_failure(run, "run_failed")
    after
      File.rm_rf(run_dir)
    end
  end

  # Walk first, scan second, write third: a secret-bearing snapshot is never
  # materialized on the action volume.
  defp load_snapshot(project, node) do
    repo = ProjectGit.open(project.id)

    case Staging.walk(repo, node.git_commit_sha, Portfolio.scan_limits()) do
      {:ok, blobs} -> {:ok, blobs}
      # The read path treats a snapshot it cannot walk within the caps as
      # unverifiable, so a run must too.
      {:error, reason} when reason in [:too_many_files, :too_many_bytes] -> {:error, :quarantined}
      {:error, _reason} -> {:error, :staging_failed}
    end
  end

  defp write_snapshot(blobs, code_dir) do
    case Staging.write(blobs, code_dir) do
      :ok -> :ok
      {:error, _reason} -> {:error, :staging_failed}
    end
  end

  defp check_content(blobs) do
    if PublicContent.quarantine?(blobs), do: {:error, :quarantined}, else: :ok
  end

  defp resolve_image(docker, project, node, code_dir, blobs) do
    cond do
      is_binary(project.docker_image) and project.docker_image != "" ->
        {:ok, project.docker_image}

      not Enum.any?(blobs, &(&1.path == "Dockerfile")) ->
        {:error, :no_image}

      true ->
        tag = image_tag(project, node)

        case docker.image?(tag) do
          {:ok, true} ->
            {:ok, tag}

          {:ok, false} ->
            files = Enum.map(blobs, & &1.path)

            case docker.build_image(code_dir, files, tag) do
              :ok -> {:ok, tag}
              {:error, _reason} -> {:error, :build_failed}
            end

          {:error, _reason} ->
            {:error, :docker_unavailable}
        end
    end
  end

  defp image_tag(project, node) do
    # Docker references are capped at 255 characters; a long slug must not make
    # the tag invalid.
    slug = project.slug |> to_string() |> String.slice(0, 40)
    "cadence-action-#{slug}-#{String.slice(node.git_commit_sha, 0, 12)}"
  end

  defp create_container(docker, run, project, node, image) do
    spec = container_spec(run, project, node, image)

    case docker.create(spec) do
      {:ok, container_id} ->
        # Record the id before starting: recovery can then remove a container
        # orphaned by a restart.
        _ = attach_container(run, container_id)
        {:ok, container_id}

      {:error, :create_failed} ->
        {:error, :create_failed}

      {:error, _reason} ->
        {:error, :docker_unavailable}
    end
  end

  # The container is always removed once it exists: start failures, wait
  # failures, and timeouts must not leave a running or stopped container behind.
  # Removal happens after the terminal write; on success the row's container id
  # is cleared, so only a *failed* removal leaves an id for the sweeper.
  defp await_and_collect(docker, run, container_id, out_dir, image) do
    result =
      try do
        case docker.start(container_id) do
          :ok ->
            {status, attrs, collect?} = await_exit(docker, container_id)
            # Heartbeat before log/artifact collection so a long collection is
            # never mistaken for a dead run.
            _ = touch(run)

            attrs =
              attrs
              |> Map.put(:container_id, container_id)
              |> Map.put(:image, image)
              |> collect_attrs(docker, run, container_id, out_dir, collect?)

            finalize(run, status, attrs)

          {:error, _reason} ->
            finish_failure(run, "docker_unavailable")
        end
      rescue
        error ->
          Logger.warning("action run collect failed: #{shape(error)}")
          finish_failure(run, "run_failed")
      catch
        kind, reason ->
          Logger.warning("action run collect exited: #{inspect(kind)}/#{shape(reason)}")
          finish_failure(run, "run_failed")
      end

    if remove_container(container_id) == :ok do
      clear_container_id(run.id)
    end

    result
  end

  # Only terminal write in await_and_collect; keep a failed removal for the sweep.
  defp clear_container_id(run_id) do
    from(r in ActionRun, where: r.id == ^run_id)
    |> Repo.update_all(set: [container_id: nil])

    :ok
  rescue
    error ->
      Logger.warning("action container id not cleared: #{shape(error)}")
      :ok
  end

  # If the container could not be stopped after a wait failure it may still be
  # running, so reading its log or /out is unsafe: force-remove it and record
  # that collection was skipped instead of copying a live tree.
  defp collect_attrs(attrs, _docker, _run, _container_id, _out_dir, false) do
    Map.put(attrs, :artifact_error, "collect_skipped")
  end

  defp collect_attrs(attrs, docker, run, container_id, out_dir, true) do
    attrs
    |> Map.merge(log_attrs(docker, run, container_id))
    |> Map.merge(artifact_attrs(run, out_dir))
  end

  defp await_exit(docker, container_id) do
    case docker.wait(container_id) do
      {:ok, 0} ->
        {:succeeded, %{exit_code: 0}, true}

      {:ok, exit_code} when is_integer(exit_code) ->
        {:failed, %{exit_code: exit_code}, true}

      {:error, :timeout} ->
        {:timed_out, %{error_reason: "timeout"}, stop_succeeded?(docker, container_id)}

      {:error, _reason} ->
        # Even a non-timeout wait failure means the container may still be
        # running; stop it before reading logs or /out.
        {:failed, %{error_reason: "run_failed"}, stop_succeeded?(docker, container_id)}
    end
  end

  defp stop_succeeded?(docker, container_id) do
    docker.stop(container_id) == :ok
  rescue
    _error -> false
  end

  defp log_attrs(docker, run, container_id) do
    case docker.logs(container_id, max_log_bytes()) do
      {:ok, log} ->
        relative = Path.join(run.id, "output.log")
        path = Path.join(artifact_root(), relative)

        case write_file(path, log) do
          :ok -> %{log_path: relative}
          :error -> %{}
        end

      {:error, _reason} ->
        %{}
    end
  end

  defp artifact_attrs(run, out_dir) do
    case Artifacts.collect(out_dir, run_artifact_dir(run), max_artifact_bytes()) do
      {:ok, []} -> %{}
      {:ok, _files} -> %{artifact_path: relative_artifact_path(run)}
      {:error, reason} -> %{artifact_error: to_string(reason)}
    end
  end

  defp container_spec(run, project, node, image) do
    limits = Actions.limits()

    %{
      name: "cadence-run-#{run.id}",
      image: image,
      command: run.command,
      working_dir: "/workspace",
      env: [
        "CADENCE_RUN_ID=#{run.id}",
        "CADENCE_NODE_ID=#{node.id}",
        "CADENCE_PROJECT_ID=#{project.id}"
      ],
      labels: %{
        "cadence.run" => run.id,
        "cadence.node" => node.id,
        "cadence.project" => project.id
      },
      mounts: [
        %{source: volume(), subpath: "#{run.id}/code", target: "/workspace", read_only: true},
        %{source: volume(), subpath: "#{run.id}/out", target: "/out", read_only: false}
      ],
      network: limits.network,
      memory_bytes: limits.memory_bytes,
      nano_cpus: limits.nano_cpus,
      pids_limit: limits.pids_limit
    }
  end

  ## Status transitions

  defp finalize(run, status, attrs) do
    transition(run, status, Map.put(attrs, :finished_at, now()))
  end

  defp finish_failure(run, reason) do
    transition(run, :failed, %{error_reason: reason, finished_at: now()})
  end

  defp transition(%ActionRun{} = run, status, attrs) do
    if status in Map.get(@allowed_transitions, run.status, []) do
      changes =
        attrs
        |> Map.take(ActionRun.transition_fields())
        |> Map.put(:status, status)
        |> Map.put(:updated_at, now())

      query =
        from(r in ActionRun,
          where: r.id == ^run.id and r.status == ^run.status
        )

      case Repo.update_all(query, set: Enum.to_list(changes)) do
        {1, _rows} ->
          updated = Repo.get!(ActionRun, run.id)
          broadcast(updated)
          # A finished run frees its slot; the next queued run starts without
          # another click. Best-effort and never changes the returned status.
          if ActionRun.terminal?(updated.status), do: dispatch(updated.project_id)
          {:ok, updated}

        {0, _rows} ->
          {:error, :stale}
      end
    else
      {:error, :stale}
    end
  end

  defp broadcast(%ActionRun{project_id: project_id, id: id, status: status}) do
    broadcast(project_id, id, status)
  end

  defp broadcast(project_id, id, status) do
    Phoenix.PubSub.broadcast(
      Cadence.Server.PubSub,
      "project:" <> project_id,
      {:action_run_updated, project_id, id, status}
    )
  rescue
    error ->
      Logger.warning("action run broadcast skipped: #{shape(error)}")
  catch
    kind, reason ->
      Logger.warning("action run broadcast exited: #{inspect(kind)}/#{shape(reason)}")
  end

  ## Validation helpers

  defp check_enabled do
    if Actions.enabled?(), do: :ok, else: {:error, :disabled}
  end

  defp fetch_project(project_id) do
    case Repo.get(Project, project_id) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  defp fetch_node(project_id, node_id) do
    case Repo.get_by(Node, id: node_id, project_id: project_id) do
      nil -> {:error, :not_found}
      node -> {:ok, node}
    end
  end

  defp authorize_manager(actor, project_id) do
    case Authorization.membership(actor_id(actor), project_id) do
      nil ->
        {:error, :forbidden}

      membership ->
        if Authorization.can_manage?(membership),
          do: {:ok, membership},
          else: {:error, :forbidden}
    end
  end

  defp authorize_viewer(actor, project_id) do
    case Authorization.membership(actor_id(actor), project_id) do
      nil ->
        {:error, :forbidden}

      membership ->
        if Authorization.can_view?(membership), do: {:ok, membership}, else: {:error, :forbidden}
    end
  end

  defp check_quarantine(project, node) do
    if Incidents.blocking_node?(project.id, node.id), do: {:error, :quarantined}, else: :ok
  end

  defp fetch_action(project, node, membership, action_name) do
    with {:ok, %{actions: actions}} <- Actions.list(project, node, membership) do
      case Enum.find(actions, &(&1.name == action_name)) do
        nil -> {:error, :unknown_action}
        action -> {:ok, action}
      end
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, :disabled} -> {:error, :disabled}
      {:error, :forbidden} -> {:error, :forbidden}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  defp insert_run(project, node, actor, action) do
    %ActionRun{}
    |> ActionRun.changeset(%{
      project_id: project.id,
      node_id: node.id,
      user_id: actor_id(actor),
      action_name: action.name,
      command: action.command
    })
    |> Repo.insert()
  end

  defp actor_id(%{id: id}), do: id
  defp actor_id(_actor), do: nil

  ## Filesystem/config

  defp run_dir(run), do: Path.join(volume_path(), run.id)
  defp run_artifact_dir(run), do: Path.join([artifact_root(), run.id, "artifacts"])
  defp relative_artifact_path(run), do: Path.join(run.id, "artifacts")

  defp ensure_run_dir(run_dir, out_dir) do
    with :ok <- mkdir(run_dir),
         :ok <- mkdir(out_dir),
         # The action image may declare a non-root USER; /out must be writable
         # by whatever uid the image runs as.
         :ok <- chmod(out_dir, 0o777) do
      :ok
    end
  end

  defp mkdir(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, _reason} -> {:error, :staging_failed}
    end
  end

  defp chmod(path, mode) do
    case File.chmod(path, mode) do
      :ok -> :ok
      {:error, _reason} -> {:error, :staging_failed}
    end
  end

  # Heartbeats keep a legitimate long staging/build/collection from looking
  # abandoned to recover_stale/1.
  defp touch(run) do
    from(r in ActionRun, where: r.id == ^run.id and r.status == :running)
    |> Repo.update_all(set: [updated_at: now()])

    :ok
  rescue
    error ->
      Logger.warning("action run heartbeat skipped: #{shape(error)}")
      :ok
  end

  defp attach_container(run, container_id) do
    from(r in ActionRun, where: r.id == ^run.id and r.status == :running)
    |> Repo.update_all(set: [container_id: container_id, updated_at: now()])

    :ok
  rescue
    error ->
      Logger.warning("action run container id not recorded: #{shape(error)}")
      :ok
  end

  defp write_file(path, content) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      case File.write(path, content) do
        :ok -> :ok
        {:error, _reason} -> :error
      end
    else
      {:error, _reason} -> :error
    end
  end

  # Injectable so a test can force the "task did not start" branch without
  # stopping the real supervisor.
  defp task_supervisor do
    Application.get_env(:cadence_server, :actions_task_supervisor, TaskSupervisor)
  end

  defp volume, do: config_str(:actions_volume, "cadence_actions")
  defp volume_path, do: config_str(:actions_volume_path, "/data/actions")
  defp artifact_root, do: Actions.artifact_path()

  defp max_log_bytes, do: config_int(:actions_max_log_bytes, 1_048_576)
  defp max_artifact_bytes, do: config_int(:actions_max_artifact_bytes, 33_554_432)

  defp clamp_limit(value) when is_integer(value) and value >= 1, do: min(value, 200)
  defp clamp_limit(_value), do: @default_list_limit

  defp stale_after_ms do
    config_int(:actions_build_timeout_ms, 300_000) + config_int(:actions_timeout_ms, 120_000) +
      @stale_margin_ms
  end

  defp error_reason(reason) do
    case reason do
      :quarantined -> "quarantined"
      :staging_failed -> "staging_failed"
      :no_image -> "no_image"
      :build_failed -> "build_failed"
      :create_failed -> "create_failed"
      :docker_unavailable -> "docker_unavailable"
      _other -> "run_failed"
    end
  end

  defp now, do: DateTime.utc_now()

  defp uuid(value) do
    case UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp config_int(key, default) do
    case Application.get_env(:cadence_server, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _other -> default
    end
  end

  defp config_str(key, default) do
    case Application.get_env(:cadence_server, key, default) do
      value when is_binary(value) and value != "" -> value
      _other -> default
    end
  end

  # Failure reasons may be raw terms from a Task supervisor; log only the shape.
  defp shape(%{__struct__: module}), do: inspect(module)
  defp shape(term) when is_atom(term), do: Atom.to_string(term)
  defp shape(term) when is_tuple(term), do: "tuple/#{tuple_size(term)}"
  defp shape(_term), do: "term"
end
