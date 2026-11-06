defmodule Cadence.Daemon.DocQueue do
  @moduledoc """
  Runs documentation jobs in the background (spec §9.3, §9.5, §9.6).

  A job is queued by `Cadence.Daemon.CommitQueue` when a commit touches a
  schema-matching path, the documentation schema, or a public API surface. It
  reads the code commit (`C1`) and its parent from the project's Git store,
  asks the doc agent for operations, and writes the result as a follow-up docs
  commit (`C2`, git parent `C1`). The node keeps its logical DAG parents but
  points at `C2`, so the next node diff and the server snapshot contain code
  and docs together.

  Doc work never blocks a commit. On failure the job retries with linear
  backoff; after `CAD_DOCS_RETRY_ATTEMPTS` the docs are left deferred
  (`docs_state: :pending`, `metadata["docs"]["state"] = "deferred"`) and the
  node is made pushable — docs are optional (spec §9.5, D6). The node's sync
  row is written with the commit but held out of selection while the job runs;
  a terminal outcome re-enqueues so the worker wakes even if the first pass
  already ran.

  A node whose SHA was already pushed is immutable. When its docs resolve
  afterwards (a push landed mid-job, a manual `:CadDocSync` after a code-only
  push, or a reconnect retry of a deferred node), the job writes `C2` and
  attaches it as a **docs child node** (`parents: [code_node.id]`,
  `metadata["docs"]["docs_for"]`) instead of rewriting the pushed SHA
  (spec §9.5).

  The working tree is the user's, not the agent's: writes are suspended for the
  project watcher, guarded per path against divergence from `C1`, and limited
  to `Cadence.Shared.Docs.Schema.allowed_path?/2`.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias Cadence.Daemon.{
    DocAgentWorker,
    Env,
    NodeStore,
    ProjectLocation,
    Repo,
    Session,
    SyncLedger,
    SyncPending,
    Watcher
  }

  alias Cadence.Daemon.Docs.SchemaSource
  alias Cadence.Shared.{GitStore, Node, UUID}
  alias Cadence.Shared.Docs.{Schema, Trigger}
  alias Cadence.Shared.LLM.{CommitMessage, Docs}

  defstruct entries: %{}

  @docs_message "docs: update project documentation"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enqueues a node's documentation job. Idempotent per node.

  `:force` skips the trigger re-check (manual `:CadDocSync`), spec §9.2.
  """
  @spec enqueue(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: :ok
  def enqueue(project_id, node_id, opts \\ []) do
    GenServer.cast(__MODULE__, {:enqueue, project_id, node_id, Keyword.get(opts, :force, false)})
  end

  @doc """
  Re-enqueues jobs that were still queued or deferred at boot. Best-effort:
  no-op when the tables are missing (the queue starts before migrations in
  tests).
  """
  @spec rehydrate() :: :ok
  def rehydrate do
    resumable_nodes()
    |> Enum.each(fn node ->
      maybe_requeue(node)
      enqueue_node(node, force: false)
    end)

    :ok
  rescue
    e in Exqlite.Error ->
      if missing_table?(e) do
        Logger.warning("doc queue rehydrate skipped before migrations: #{Exception.message(e)}")
        :ok
      else
        reraise e, __STACKTRACE__
      end
  end

  @doc """
  Re-enqueues pending and deferred doc jobs (reconnect/manual recovery).

  `:CadDocSync` and a successful reconnect use this; a local deferred node is
  moved back to `pending` (so sync holds it again) and keeps its
  `code_commit_sha` so the job can still build `C2` (spec §9.5).

  Pass a `project_id` to scope recovery to the reconnected project; omit it for
  a daemon-wide pass. A node already pushed keeps its SHA; the retry attaches
  the docs as a child node.
  """
  @spec retry_pending(Ecto.UUID.t() | nil) :: :ok
  def retry_pending(project_id \\ nil) do
    resumable_nodes(project_id)
    |> Enum.each(fn node ->
      maybe_requeue(node)
      enqueue_node(node, force: false)
    end)

    :ok
  rescue
    e in Exqlite.Error ->
      if missing_table?(e) do
        :ok
      else
        reraise e, __STACKTRACE__
      end
  end

  @doc """
  Queues a manual (`:CadDocSync`) documentation job and reports the decision
  synchronously (spec §9.2).

  `node_id` defaults to the session anchor (current pointer, then the local
  user's newest node, then the preview node). Manual sync bypasses the trigger
  re-check but still respects `CAD_DOCS_ENABLED`. A node with generated docs
  (`docs_state: :current`) is reported as `:already_current` rather than
  regenerated.

  Ownership decides how the docs are attached (spec §9.5):

    * a node with a `SyncPending` row and no pushed stamp is local, so its SHA
      may still move to `C2` — the node is marked docs-pending first so
      `SyncLedger` holds it out of the push queue while the model runs
    * a node stamped as pushed at its current SHA (`docs_pushed_sha`) is
      immutable — the job attaches the docs as a follow-up child node, and the
      pushed parent is neither re-held nor re-queued
    * anything else (a pulled node, or a pre-5b node with no stamp) is reported
      as `:legacy`: there is no local proof that forcing docs is safe.

  A held node (`metadata["docs"]["state"] == "pending"`) is released with the
  same terminal transition the job would use when the manual preflight skips or
  fails.

  Returns:

    * `{:queued, node_id}` — the job was accepted by the queue. The id is the
      node the docs were requested for; a pushed node's docs land in a child
      node, and the requested node's metadata then points at that `C2`
    * `{:skipped, reason}` — `:already_current`, `:legacy`, `:disabled`,
      `:no_schema`, or `:invalid_schema`
    * `{:error, reason}` — `:invalid_project`, `:invalid_node`, `:not_found`,
      `:no_node`, `:no_location`, `:not_configured`, or
      `:node_update_failed`
  """
  @spec sync(Ecto.UUID.t(), Ecto.UUID.t() | nil) ::
          {:queued, Ecto.UUID.t()} | {:skipped, atom()} | {:error, atom()}
  def sync(project_id, node_id \\ nil) do
    with {:ok, project_id} <- cast_project(project_id),
         {:ok, node} <- sync_node(project_id, node_id) do
      decision =
        case project_work_dir(project_id) do
          {:ok, work_dir} -> decide(node, work_dir)
          {:error, _reason} = error -> error
        end

      case decision do
        :ok ->
          case arm(node) do
            :ok ->
              enqueue(project_id, node.id, force: true)
              {:queued, node.id}

            {:skip, reason} ->
              {:skipped, reason}

            {:error, reason} ->
              {:error, reason}
          end

        {:skip, reason} ->
          maybe_release(node, reason)
          {:skipped, reason}

        {:error, reason} ->
          maybe_release(node, reason)
          {:error, reason}
      end
    else
      {:error, _reason} = error -> error
    end
  end

  defp decide(node, work_dir) do
    with :ok <- check_current(node),
         :ok <- check_mode(node),
         :ok <- check_enabled(),
         :ok <- check_schema(work_dir),
         :ok <- check_configured() do
      :ok
    end
  end

  # A pushed node needs nothing held: the docs child gets its own sync row when
  # it is created. A local node is held out of the push queue while the model
  # runs so its SHA can still move from `C1` to `C2` (spec §9.5).
  defp arm(node) do
    case docs_mode(node) do
      :child -> :ok
      :local -> mark_pending(node)
      :legacy -> {:skip, :legacy}
    end
  end

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_cast({:enqueue, project_id, node_id, force}, state) do
    case Map.get(state.entries, node_id) do
      nil ->
        entry = %{project_id: project_id, attempts: 0, force: force}
        schedule_retry(node_id, 0)
        {:noreply, %{state | entries: Map.put(state.entries, node_id, entry)}}

      entry ->
        # A manual `:CadDocSync` may race the automatic job; the manual request
        # must still bypass the trigger re-check rather than be swallowed.
        updated = %{entry | force: entry.force or force}
        {:noreply, %{state | entries: Map.put(state.entries, node_id, updated)}}
    end
  end

  @impl true
  def handle_info({:retry, node_id}, state) do
    case Map.get(state.entries, node_id) do
      nil ->
        {:noreply, state}

      entry ->
        result =
          try do
            run(node_id, entry)
          rescue
            error ->
              Logger.error("doc job crashed for node #{node_id}: #{inspect(error.__struct__)}")

              crashed(node_id, entry)
          end

        case result do
          :ok ->
            {:noreply, %{state | entries: Map.delete(state.entries, node_id)}}

          {:retry, entry} ->
            schedule_retry(node_id, entry.attempts)
            {:noreply, %{state | entries: Map.put(state.entries, node_id, entry)}}

          :drop ->
            {:noreply, %{state | entries: Map.delete(state.entries, node_id)}}
        end
    end
  end

  defp run(node_id, entry) do
    case Repo.get(Node, node_id) do
      nil ->
        :drop

      node ->
        cond do
          # A pulled or pre-5b node has no local proof of provenance: forcing
          # docs could rewrite a SHA the server already owns or detach it.
          docs_mode(node) == :legacy ->
            :drop

          not entry.force and not Env.docs_enabled?() ->
            # A local node is released to sync as `:skipped`; a pushed node has
            # nothing to release, and keeping its deferred state lets a later
            # retry still attach the docs child (spec §9.5).
            if pushed?(node) do
              :drop
            else
              mark_skipped(node, :disabled)
              :ok
            end

          entry.force or (docs_state(node) in ["pending", "deferred"] and docs_job?(node)) ->
            execute_or_fail(node, entry)

          true ->
            :drop
        end
    end
  end

  defp crashed(node_id, entry) do
    case Repo.get(Node, node_id) do
      nil -> :drop
      node -> handle_failure(node, entry, :crashed)
    end
  end

  defp execute_or_fail(node, entry) do
    case execute(node, entry.force) do
      {:ok, sync_node} ->
        # A reused child may already be on the server; never re-queue it.
        enqueue_local_sync({:ok, sync_node})
        :ok

      {:skip, reason} ->
        mark_skipped(node, reason)
        :ok

      {:error, reason} ->
        handle_failure(node, entry, reason)
    end
  end

  # The watcher stays suspended across the working-tree write *and* the node
  # write: a file event that arrives just after the write would otherwise commit
  # the docs tree against the code node and create a duplicate node.
  defp execute(node, force) do
    Watcher.suspend(node.project_id)

    try do
      with {:ok, code_sha} <- code_commit_sha(node, force),
           {:ok, git} <- NodeStore.open(node.project_id),
           {:ok, commit} <- NodeStore.read_commit(git, code_sha),
           {:ok, old_tree} <- NodeStore.parent_tree(git, node.parents),
           {:ok, schema, work_dir} <- load_schema(node.project_id),
           changes = GitStore.diff_trees(git, old_tree, commit.tree),
           :ok <- trigger_gate(force, schema, changes),
           {:ok, docs, unreadable} <- read_docs(git, code_sha, schema),
           diff_text = CommitMessage.diff_to_text(changes, Env.docs_diff_max_bytes()),
           {:ok, ops} <-
             DocAgentWorker.generate(schema, docs, diff_text, read_only_paths: unreadable),
           {:ok, updated} <- apply_ops(schema, docs, ops),
           {:ok, docs_sha, changed} <-
             write_docs_commit(git, commit.tree, code_sha, docs, updated),
           {:ok, skipped_paths} <- write_worktree(node, work_dir, schema, docs, changed),
           {:ok, sync_node} <- record_result(node, code_sha, docs_sha, changed, skipped_paths) do
        {:ok, sync_node}
      else
        :skip -> {:skip, :trigger}
        {:error, :no_schema} = _error -> {:skip, :no_schema}
        {:error, _reason} = error -> error
      end
    after
      Watcher.resume(node.project_id)
    end
  end

  ## Job inputs

  defp code_commit_sha(node, force \\ false) do
    meta = docs_meta(node)

    case meta["code_commit_sha"] || node.session_metadata["code_commit_sha"] do
      sha when is_binary(sha) -> {:ok, sha}
      _ when force -> {:ok, node.git_commit_sha}
      _ -> {:error, :missing_code_commit}
    end
  end

  defp docs_job?(node) do
    Map.has_key?(docs_meta(node), "code_commit_sha") or
      is_binary(node.session_metadata["code_commit_sha"])
  end

  defp load_schema(project_id) do
    case Repo.get(ProjectLocation, project_id) do
      %ProjectLocation{work_dir: work_dir} ->
        case SchemaSource.load(work_dir) do
          {:ok, schema} -> {:ok, schema, work_dir}
          :no_schema -> {:error, :no_schema}
          {:error, _reason} = error -> error
        end

      nil ->
        {:error, :no_location}
    end
  end

  defp trigger_gate(true = _force, _schema, _changes), do: :ok

  defp trigger_gate(_force, schema, changes) do
    case Trigger.reasons(schema, changes) do
      {:run, _reasons} -> :ok
      :skip -> :skip
    end
  end

  defp apply_ops(schema, docs, ops) do
    with {:ok, updated} <- Docs.apply_ops(docs, ops),
         :ok <- Docs.validate_required(schema, updated) do
      {:ok, updated}
    end
  end

  ## Reading the committed docs

  defp read_docs(git, commit_sha, schema) do
    with {:ok, paths} <- doc_paths(git, commit_sha, schema) do
      # Read at most twice the prompt budget; anything beyond is marked
      # read-only so the model can never rewrite a file it did not see.
      budget = max(Env.docs_context_bytes() * 2, 65_536)

      {docs, unreadable, _bytes} =
        Enum.reduce(paths, {%{}, [], 0}, fn path, {docs, unreadable, bytes} ->
          case GitStore.read_path(git, commit_sha, path, max_bytes: Env.docs_max_file_bytes()) do
            {:ok, content} ->
              cond do
                path == schema.index_file ->
                  {Map.put(docs, path, content), unreadable, bytes + byte_size(content)}

                bytes + byte_size(content) <= budget ->
                  {Map.put(docs, path, content), unreadable, bytes + byte_size(content)}

                true ->
                  {docs, [path | unreadable], bytes}
              end

            {:error, :not_found} ->
              {docs, unreadable, bytes}

            {:error, :not_a_file} ->
              # A schema path that is a tree entry, not a file: keep it
              # read-only so the agent cannot CREATE over unseen content.
              {docs, [path | unreadable], bytes}

            {:error, _reason} ->
              {docs, [path | unreadable], bytes}
          end
        end)

      {:ok, docs, Enum.reverse(unreadable)}
    end
  end

  defp doc_paths(git, commit_sha, schema) do
    limit = max(Env.docs_max_files(), 1)

    # Request one extra file so "exactly the limit" is allowed and only a
    # genuinely over-limit directory is refused.
    case list_doc_paths(git, commit_sha, schema.docs_dir, limit + 1, []) do
      {:ok, found, _remaining} -> finish_doc_paths(schema, found, limit)
      {:error, _reason} = error -> error
    end
  end

  # Refuse rather than silently ignore docs beyond the cap: an unlisted file is
  # one the agent could otherwise CREATE over without having seen its content.
  defp finish_doc_paths(_schema, found, limit) when length(found) > limit do
    {:error, :too_many_docs}
  end

  defp finish_doc_paths(schema, found, _limit),
    do: {:ok, Enum.uniq([schema.index_file | found])}

  defp list_doc_paths(_git, _commit_sha, _dir, 0 = _remaining, acc), do: {:ok, acc, 0}

  defp list_doc_paths(git, commit_sha, dir, remaining, acc) do
    case GitStore.list_path(git, commit_sha, dir, max_entries: max(remaining, 1)) do
      {:ok, entries, _truncated} ->
        Enum.reduce_while(entries, {:ok, acc, remaining}, fn entry, {:ok, acc, left} ->
          cond do
            left <= 0 ->
              {:halt, {:ok, acc, left}}

            entry.type == :blob ->
              {:cont, {:ok, [entry.path | acc], left - 1}}

            true ->
              case list_doc_paths(git, commit_sha, entry.path, left, acc) do
                {:ok, acc, left} -> {:cont, {:ok, acc, left}}
                {:error, _reason} = error -> {:halt, error}
              end
          end
        end)

      {:error, :not_found} ->
        {:ok, acc, remaining}

      {:error, _reason} = error ->
        error
    end
  end

  ## Writing the docs commit and the working tree

  defp write_docs_commit(git, tree, code_sha, docs, updated) do
    changed =
      updated
      |> Enum.reject(fn {path, content} -> Map.get(docs, path) == content end)
      |> Map.new()

    if map_size(changed) == 0 do
      {:ok, nil, changed}
    else
      with {:ok, docs_tree} <- GitStore.merge_files(git, tree, changed) do
        docs_sha =
          GitStore.write_commit(
            git,
            docs_tree,
            [code_sha],
            Env.git_author(),
            @docs_message
          )

        {:ok, docs_sha, changed}
      end
    end
  end

  defp write_worktree(_node, _work_dir, _schema, _docs, changed) when map_size(changed) == 0 do
    {:ok, []}
  end

  defp write_worktree(_node, work_dir, schema, docs, changed) do
    skipped =
      changed
      |> Enum.sort_by(fn {path, _content} -> path end)
      |> Enum.reduce([], fn {path, content}, skipped ->
        if Schema.allowed_path?(schema, path) do
          case write_doc(work_dir, path, content, Map.get(docs, path)) do
            :ok -> skipped
            :skip -> [path | skipped]
          end
        else
          [path | skipped]
        end
      end)

    {:ok, Enum.reverse(skipped)}
  end

  # Write only when the file still matches the committed `C1` content (or does
  # not exist); otherwise the user edited it while the job ran. Symlinked files
  # or parent directories are never written through.
  defp write_doc(work_dir, path, content, committed) do
    full = Path.expand(path, work_dir)
    root = Path.expand(work_dir)

    with true <- String.starts_with?(full, root <> "/"),
         :ok <- safe_parent_dirs(work_dir, path),
         :ok <- regular_or_absent(full),
         {:ok, disk} <- read_disk(full),
         :ok <- writable?(disk, content, committed),
         :ok <- File.mkdir_p(Path.dirname(full)) do
      case File.write(full, content) do
        :ok -> :ok
        {:error, _reason} -> :skip
      end
    else
      _ -> :skip
    end
  end

  defp safe_parent_dirs(work_dir, path) do
    case Path.dirname(path) do
      "." ->
        :ok

      dirname ->
        dirname
        |> String.split("/", trim: true)
        |> Enum.reduce_while(Path.expand(work_dir), fn part, dir ->
          next = Path.join(dir, part)

          case File.lstat(next) do
            {:ok, %File.Stat{type: :directory}} -> {:cont, next}
            {:error, :enoent} -> {:halt, :ok}
            _other -> {:halt, :skip}
          end
        end)
        |> case do
          :ok -> :ok
          :skip -> :skip
          _dir -> :ok
        end
    end
  end

  defp regular_or_absent(full) do
    case File.lstat(full) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:error, :enoent} -> :ok
      _other -> :skip
    end
  end

  defp read_disk(full) do
    case File.read(full) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:ok, :absent}
      {:error, _reason} -> {:error, :unreadable}
    end
  end

  defp writable?(:absent, _content, _committed), do: :ok
  defp writable?(disk, content, _committed) when disk == content, do: :ok
  defp writable?(disk, _content, committed) when disk == committed, do: :ok
  defp writable?(_disk, _content, _committed), do: :skip

  ## Node updates

  # The job finished; decide where the docs attach. A pushed node's SHA is
  # immutable, so its docs become a child node instead (spec §9.5). The node is
  # re-read here because the sync worker may have pushed it while the model ran,
  # and the write itself is conditional so a stamp that lands during the write is
  # never overwritten by a stale map (see `write_current/5`).
  defp record_result(node, code_sha, docs_sha, changed, skipped_paths, retries \\ 1) do
    case Repo.get(Node, node.id) do
      nil ->
        {:error, :not_found}

      current ->
        case existing_child(current) do
          %Node{} = child ->
            {:ok, child}

          nil ->
            if pushed?(current) and is_binary(docs_sha) and docs_sha != current.git_commit_sha do
              create_docs_child(current, code_sha, docs_sha, changed, skipped_paths)
            else
              case write_current(current, code_sha, docs_sha, changed, skipped_paths) do
                :stale when retries > 0 ->
                  # Another writer (the sync worker's pushed-SHA stamp, or the
                  # message queue) changed the row while the model ran. Re-read
                  # once and take the path the fresh row requires.
                  record_result(node, code_sha, docs_sha, changed, skipped_paths, retries - 1)

                :stale ->
                  {:error, :pushed}

                result ->
                  result
              end
            end
        end
    end
  end

  # Move the node to `C2` in place. The update is conditional on the node not
  # having been stamped as pushed in the meantime: a stamp means the server owns
  # the SHA, and writing `C2` here (and rebuilding `session_metadata` from a
  # stale read) would move an immutable SHA and erase the provenance stamp.
  defp write_current(current, code_sha, docs_sha, changed, skipped_paths) do
    # A pushed SHA is immutable. The only safe outcome for a pushed node here is
    # a no-op generation that leaves the SHA alone; anything else is a bug.
    if pushed?(current) and docs_final_sha(current, code_sha, docs_sha) != current.git_commit_sha do
      {:error, :pushed}
    else
      previous_sha = docs_meta(current)["docs_commit_sha"]
      final_sha = docs_final_sha(current, code_sha, docs_sha)

      docs =
        docs_metadata(code_sha, docs_sha || previous_sha, changed, skipped_paths)
        |> keep_legacy_stamp(current)

      metadata =
        current.session_metadata
        |> Map.put("docs", docs)
        |> Map.put("code_commit_sha", code_sha)

      # A stamp written between `current`'s read and this update means the server
      # just took the SHA: refuse the write so the caller re-reads and takes the
      # child path instead. When we already read the stamp, writing it back is
      # safe (a stamped node only reaches here for a SHA-preserving no-op).
      own_stamp = current.session_metadata["docs_pushed_sha"]

      query =
        case own_stamp do
          nil ->
            from(n in Node,
              where:
                n.id == ^current.id and
                  is_nil(fragment("json_extract(?, '$.docs_pushed_sha')", n.session_metadata))
            )

          sha ->
            from(n in Node,
              where:
                n.id == ^current.id and
                  fragment("json_extract(?, '$.docs_pushed_sha')", n.session_metadata) == ^sha
            )
        end

      case Repo.update_all(query,
             set: [
               git_commit_sha: final_sha,
               docs_state: :current,
               session_metadata: metadata
             ]
           ) do
        {1, _} -> {:ok, Repo.get!(Node, current.id)}
        {0, _} -> :stale
      end
    end
  end

  # Older stamps lived inside the docs map; keep one so replacing the map does
  # not strip the node's pushed provenance.
  defp keep_legacy_stamp(docs, node) do
    case docs_meta(node)["pushed_sha"] do
      sha when is_binary(sha) -> Map.put(docs, "pushed_sha", sha)
      _ -> docs
    end
  end

  # The pushed node keeps its SHA and records where its docs went; the child is
  # a real node with its own sync row, so the server receives `C2` as a
  # descendant of the code commit it already has.
  defp create_docs_child(node, code_sha, docs_sha, changed, skipped_paths) do
    child_id = Ecto.UUID.generate()

    parent_docs =
      docs_metadata(code_sha, docs_sha, changed, skipped_paths)
      |> keep_legacy_stamp(node)
      |> Map.put("docs_child_id", child_id)

    child_docs =
      docs_metadata(code_sha, docs_sha, changed, skipped_paths)
      |> Map.put("docs_for", node.id)

    attrs = %{
      id: child_id,
      project_id: node.project_id,
      git_commit_sha: docs_sha,
      parents: [node.id],
      flags: [:"in-progress"],
      pinned: false,
      message: @docs_message,
      session_metadata: %{"code_commit_sha" => code_sha, "docs" => child_docs},
      created_by: Env.local_user_id(),
      created_at: DateTime.utc_now(),
      docs_state: :current
    }

    Repo.transaction(fn ->
      parent_metadata = Map.put(node.session_metadata, "docs", parent_docs)

      # The parent is already pushed, but another writer (message queue, a
      # re-push) may have added a key since `node` was read. Only update the
      # row we read; a miss rolls the whole child back and retries.
      {count, _} =
        Repo.update_all(
          from(n in Node,
            where: n.id == ^node.id and n.git_commit_sha == ^node.git_commit_sha
          ),
          set: [docs_state: :current, session_metadata: parent_metadata]
        )

      if count == 0, do: Repo.rollback(:stale)

      with {:ok, child} <- attrs |> Node.changeset() |> Repo.insert(),
           :ok <- SyncLedger.insert_pending!(child),
           {:ok, _membership} <- Session.docs_after(node.project_id, node, child) do
        child
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Idempotency: a repeated job for the same code node reuses the child it
  # already attached instead of fanning out a duplicate node.
  defp existing_child(node) do
    with id when is_binary(id) <- docs_meta(node)["docs_child_id"],
         {:ok, id} <- UUID.cast(id),
         %Node{} = child <- Repo.get(Node, id) do
      child
    else
      _ -> nil
    end
  end

  defp docs_metadata(code_sha, docs_sha, changed, skipped_paths) do
    %{
      "state" => "current",
      "code_commit_sha" => code_sha,
      "model" => DocAgentWorker.model(),
      "provider" => DocAgentWorker.provider(),
      "prompt_version" => DocAgentWorker.prompt_version(),
      "paths" => changed |> Map.keys() |> Enum.sort(),
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
    |> put_docs_commit(docs_sha)
    |> maybe_put_skipped(skipped_paths)
  end

  defp docs_final_sha(current, code_sha, docs_sha) do
    docs_sha || docs_meta(current)["docs_commit_sha"] || code_sha
  end

  defp put_docs_commit(docs, docs_sha) when is_binary(docs_sha) do
    Map.put(docs, "docs_commit_sha", docs_sha)
  end

  # No operations means the docs were already current; no `C2` exists, so the
  # diff surface reports "no docs commit" rather than an empty one (§9.4).
  defp put_docs_commit(docs, nil), do: Map.put(docs, "empty", true)

  defp mark_skipped(node, reason) do
    node.id
    |> update_node(fn current ->
      if docs_meta(current)["state"] == "current" do
        current
      else
        metadata =
          Map.put(current.session_metadata, "docs", %{
            "state" => "skipped",
            "reason" => reason_string(reason)
          })

        Node.changeset(current, %{docs_state: :skipped, session_metadata: metadata})
      end
    end)
    |> enqueue_local_sync()

    :ok
  end

  defp mark_deferred(node, reason) do
    node.id
    |> update_node(fn current ->
      if docs_meta(current)["state"] == "current" do
        current
      else
        docs =
          current
          |> docs_meta()
          |> Map.put("state", "deferred")
          |> Map.put("error", reason_string(reason))

        metadata = Map.put(current.session_metadata, "docs", docs)
        Node.changeset(current, %{docs_state: :pending, session_metadata: metadata})
      end
    end)
    |> enqueue_local_sync()

    :ok
  end

  defp store_error(node, reason) do
    docs =
      node
      |> docs_meta()
      |> Map.put("state", "pending")
      |> Map.put("error", reason_string(reason))

    update_node(node.id, fn current ->
      Node.changeset(current, %{
        session_metadata: Map.put(current.session_metadata, "docs", docs)
      })
    end)
  end

  defp handle_failure(node, entry, reason) do
    attempts = entry.attempts + 1

    cond do
      terminal?(reason) ->
        mark_deferred(node, reason)
        :drop

      attempts >= Env.docs_retry_attempts() ->
        mark_deferred(node, reason)
        :drop

      true ->
        store_error(node, reason)
        {:retry, %{entry | attempts: attempts}}
    end
  end

  # Retrying cannot fix a missing client, commit, project location, or an
  # unlistable docs directory.
  defp terminal?(:not_configured), do: true
  defp terminal?(:missing_code_commit), do: true
  defp terminal?(:no_location), do: true
  defp terminal?(:too_many_docs), do: true
  defp terminal?(:context_too_large), do: true
  defp terminal?(:pushed), do: true
  defp terminal?(_reason), do: false

  defp maybe_put_skipped(docs, []), do: docs
  defp maybe_put_skipped(docs, paths), do: Map.put(docs, "workdir_skipped", paths)

  defp update_node(node_id, fun) do
    case Repo.get(Node, node_id) do
      nil ->
        {:error, :not_found}

      node ->
        node
        |> fun.()
        |> write_node()
    end
  end

  # A no-op transition returns the node unchanged; writing it back would raise
  # (and must not bump anything), so only changesets are persisted.
  defp write_node(%Ecto.Changeset{} = changeset), do: Repo.update(changeset)
  defp write_node(%Node{} = node), do: {:ok, node}

  ## Manual sync

  defp cast_project(project_id) do
    case UUID.cast(project_id) do
      {:ok, project_id} -> {:ok, project_id}
      :error -> {:error, :invalid_project}
    end
  end

  defp sync_node(project_id, nil) do
    case Session.anchor_node(project_id) do
      %Node{project_id: ^project_id} = node -> {:ok, node}
      _ -> {:error, :no_node}
    end
  end

  defp sync_node(project_id, node_id) do
    with {:ok, node_id} <- UUID.cast(node_id),
         %Node{project_id: ^project_id} = node <- Repo.get(Node, node_id) do
      {:ok, node}
    else
      :error -> {:error, :invalid_node}
      _ -> {:error, :not_found}
    end
  end

  defp project_work_dir(project_id) do
    case Repo.get(ProjectLocation, project_id) do
      %ProjectLocation{work_dir: work_dir} -> {:ok, work_dir}
      nil -> {:error, :no_location}
    end
  end

  # How a node's docs may be attached (spec §9.5):
  #
  #   * `:child`  — the node carries a pushed-SHA stamp, so its current SHA is
  #     (or was) on the server; docs must become a follow-up node
  #   * `:local`  — the node has a `SyncPending` row and no stamp, so its SHA may
  #     still move from `C1` to `C2` in place
  #   * `:legacy` — neither: a pulled node has no row and pre-5b nodes have no
  #     stamp, so there is no local proof that forcing docs is safe
  defp docs_mode(node) do
    cond do
      pushed?(node) -> :child
      unpushed?(node.id) -> :local
      true -> :legacy
    end
  end

  defp check_mode(node) do
    if docs_mode(node) == :legacy, do: {:skip, :legacy}, else: :ok
  end

  defp unpushed?(node_id), do: Repo.get(SyncPending, node_id) != nil

  # Spawns also carry `docs_state: :current` with empty docs metadata; only a
  # generation result (metadata `state: "current"`) counts as already current.
  defp check_current(node) do
    if node.docs_state == :current and docs_meta(node)["state"] == "current" do
      {:skip, :already_current}
    else
      :ok
    end
  end

  defp check_enabled, do: if(Env.docs_enabled?(), do: :ok, else: {:skip, :disabled})

  defp check_schema(work_dir) do
    case SchemaSource.load(work_dir) do
      {:ok, _schema} -> :ok
      :no_schema -> {:skip, :no_schema}
      {:error, _reason} -> {:skip, :invalid_schema}
    end
  end

  defp check_configured do
    if DocAgentWorker.configured?(), do: :ok, else: {:error, :not_configured}
  end

  # Arm the sync hold before a manual job. `SyncLedger` only holds nodes whose
  # metadata docs state is "pending" (spec §9.5); without this the worker can
  # push C1 while the model is running, and the job would then rewrite a
  # pushed SHA. A concurrent success wins: return `:already_current` instead
  # of re-arming it.
  defp mark_pending(node) do
    code_sha =
      docs_meta(node)["code_commit_sha"] ||
        node.session_metadata["code_commit_sha"] ||
        node.git_commit_sha

    case update_node(node.id, fn current ->
           if docs_meta(current)["state"] == "current" do
             current
           else
             docs =
               current
               |> docs_meta()
               |> Map.put("state", "pending")
               |> Map.put("code_commit_sha", code_sha)
               |> Map.delete("error")

             Node.changeset(current, %{
               docs_state: :pending,
               session_metadata: Map.put(current.session_metadata, "docs", docs)
             })
           end
         end) do
      {:ok, %Node{} = updated} ->
        if docs_meta(updated)["state"] == "current", do: {:skip, :already_current}, else: :ok

      {:error, _reason} ->
        {:error, :node_update_failed}
    end
  end

  # A queued local node is held out of sync until its doc job reaches a terminal
  # state. If the manual preflight skips or fails, release it with the same
  # transition the job would use so it cannot stay stranded (spec §9.5). A
  # pushed node has no row to release and nothing to strand: leave its deferred
  # docs state alone so a later retry can still attach the child.
  defp maybe_release(node, reason) do
    if docs_meta(node)["state"] == "pending" and docs_mode(node) == :local do
      case reason do
        :disabled -> mark_skipped(node, reason)
        :no_schema -> mark_skipped(node, reason)
        :legacy -> mark_skipped(node, reason)
        :invalid_schema -> mark_deferred(node, reason)
        :not_configured -> mark_deferred(node, reason)
        :no_location -> mark_deferred(node, reason)
        _ -> :ok
      end
    end
  end

  ## Helpers

  defp docs_meta(node) do
    case node.session_metadata do
      %{"docs" => %{} = docs} -> docs
      _ -> %{}
    end
  end

  defp docs_state(node), do: docs_meta(node)["state"]

  # A pushed node's SHA is immutable. The top-level key also covers skipped
  # nodes, which have no `docs` map. The stamp records the SHA the server
  # received.
  defp pushed?(node) do
    is_binary(node.session_metadata["docs_pushed_sha"]) or
      is_binary(docs_meta(node)["pushed_sha"])
  end

  # A skipped or deferred pushed node must not be re-queued for sync: its row is
  # gone and its SHA is already on the server (spec §9.5).
  defp enqueue_local_sync({:ok, %Node{} = node}) do
    if pushed?(node), do: :ok, else: SyncLedger.enqueue(node.project_id, node.id)
  end

  defp enqueue_local_sync({:error, _reason}), do: :ok

  defp node_ids(nil) do
    Node
    |> where([n], n.docs_state == ^:pending)
    |> Repo.all()
  end

  defp node_ids(project_id) do
    case UUID.cast(project_id) do
      {:ok, project_id} ->
        Node
        |> where([n], n.docs_state == ^:pending and n.project_id == ^project_id)
        |> Repo.all()

      :error ->
        []
    end
  end

  # Resume local jobs, plus a pushed node whose docs are still deferred: its SHA
  # cannot move, so the job attaches the docs as a child node (spec §9.5). A
  # pulled node has no `SyncPending` row and no stamp, so regenerating docs for
  # it would rewrite a SHA the server already owns — never resume it.
  defp resumable_nodes(project_id \\ nil) do
    node_ids(project_id)
    |> Enum.filter(fn node ->
      docs_state(node) in ["pending", "deferred"] and docs_job?(node) and
        (unpushed?(node.id) or pushed?(node))
    end)
  end

  defp enqueue_node(node, opts) do
    case code_commit_sha(node) do
      {:ok, _sha} -> enqueue(node.project_id, node.id, opts)
      {:error, _reason} -> :ok
    end
  end

  # Re-arm sync gating before a deferred job runs again, so a retry that is
  # still in flight is not pushed as the code-only node. A pushed node has no
  # row to hold; its docs will land in a child node instead.
  defp maybe_requeue(%Node{} = node) do
    if docs_state(node) == "deferred" and not pushed?(node), do: mark_pending(node)

    :ok
  end

  defp schedule_retry(node_id, attempt) do
    Process.send_after(self(), {:retry, node_id}, backoff_ms(attempt))
  end

  defp backoff_ms(0), do: 0

  defp backoff_ms(attempt) do
    Env.docs_retry_backoff_ms() * attempt
  end

  defp reason_string(reason) do
    reason
    |> inspect(limit: 10, printable_limit: 200)
    |> String.slice(0, 200)
  end

  defp missing_table?(error) do
    String.contains?(Exception.message(error), "no such table")
  end
end
