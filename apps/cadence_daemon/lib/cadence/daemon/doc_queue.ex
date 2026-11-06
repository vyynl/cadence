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
    SyncLedger,
    Watcher
  }

  alias Cadence.Daemon.Docs.SchemaSource
  alias Cadence.Shared.{GitStore, Node, UUID}
  alias Cadence.Shared.Docs.{Schema, Trigger}
  alias Cadence.Shared.LLM.{CommitMessage, Docs}

  defstruct entries: %{}

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

  `:CadDocSync` and a successful reconnect use this; a deferred node is moved
  back to `pending` (so sync holds it again) and keeps its `code_commit_sha` so
  the job can still build `C2` (spec §9.5).

  Pass a `project_id` to scope recovery to the reconnected project; omit it for
  a daemon-wide pass. Nodes already pushed are skipped (their SHA is immutable
  until the P4-T2 child-node fallback).
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

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_cast({:enqueue, project_id, node_id, force}, state) do
    if Map.has_key?(state.entries, node_id) do
      {:noreply, state}
    else
      entry = %{project_id: project_id, attempts: 0, force: force}
      schedule_retry(node_id, 0)
      {:noreply, %{state | entries: Map.put(state.entries, node_id, entry)}}
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
          pushed?(node) ->
            :drop

          not entry.force and not Env.docs_enabled?() ->
            mark_skipped(node, :disabled)
            :ok

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
      :ok ->
        SyncLedger.enqueue(node.project_id, node.id)
        :ok

      {:skip, reason} ->
        mark_skipped(node, reason)
        :ok

      {:error, reason} ->
        handle_failure(node, entry, reason)
    end
  end

  defp execute(node, force) do
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
         {:ok, docs_sha, changed} <- write_docs_commit(git, commit.tree, code_sha, docs, updated),
         {:ok, skipped_paths} <- write_worktree(node, work_dir, schema, docs, changed),
         {:ok, _node} <- mark_current(node, code_sha, docs_sha, changed, skipped_paths) do
      :ok
    else
      :skip -> {:skip, :trigger}
      {:error, :no_schema} = _error -> {:skip, :no_schema}
      {:error, _reason} = error -> error
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
            "docs: update project documentation"
          )

        {:ok, docs_sha, changed}
      end
    end
  end

  defp write_worktree(_node, _work_dir, _schema, _docs, changed) when map_size(changed) == 0 do
    {:ok, []}
  end

  defp write_worktree(node, work_dir, schema, docs, changed) do
    Watcher.suspend(node.project_id)

    try do
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
    after
      Watcher.resume(node.project_id)
    end
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

  defp mark_current(node, code_sha, docs_sha, changed, skipped_paths) do
    update_node(node.id, fn current ->
      # A forced no-op run must not rewind a node that already points at C2.
      previous_sha = docs_meta(current)["docs_commit_sha"]
      final_sha = docs_sha || previous_sha || code_sha

      docs =
        %{
          "state" => "current",
          "code_commit_sha" => code_sha,
          "model" => DocAgentWorker.model(),
          "provider" => DocAgentWorker.provider(),
          "prompt_version" => DocAgentWorker.prompt_version(),
          "paths" => changed |> Map.keys() |> Enum.sort(),
          "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
        |> put_docs_commit(docs_sha || previous_sha)
        |> maybe_put_skipped(skipped_paths)

      metadata =
        current.session_metadata
        |> Map.put("docs", docs)
        |> Map.put("code_commit_sha", code_sha)

      Node.changeset(current, %{
        git_commit_sha: final_sha,
        docs_state: :current,
        session_metadata: metadata
      })
    end)
  end

  defp put_docs_commit(docs, docs_sha) when is_binary(docs_sha) do
    Map.put(docs, "docs_commit_sha", docs_sha)
  end

  # No operations means the docs were already current; no `C2` exists, so the
  # diff surface reports "no docs commit" rather than an empty one (§9.4).
  defp put_docs_commit(docs, nil), do: Map.put(docs, "empty", true)

  defp mark_skipped(node, reason) do
    update_node(node.id, fn current ->
      metadata =
        Map.put(current.session_metadata, "docs", %{
          "state" => "skipped",
          "reason" => reason_string(reason)
        })

      Node.changeset(current, %{docs_state: :skipped, session_metadata: metadata})
    end)

    SyncLedger.enqueue(node.project_id, node.id)
    :ok
  end

  defp mark_deferred(node, reason) do
    docs =
      node
      |> docs_meta()
      |> Map.put("state", "deferred")
      |> Map.put("error", reason_string(reason))

    update_node(node.id, fn current ->
      metadata = Map.put(current.session_metadata, "docs", docs)

      Node.changeset(current, %{docs_state: :pending, session_metadata: metadata})
    end)

    SyncLedger.enqueue(node.project_id, node.id)
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
        |> Repo.update()
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

  # A pushed node's SHA is immutable; the P4-T2 child-node fallback owns docs
  # generated after a push (spec §9.5). The top-level key also covers skipped
  # nodes, which have no `docs` map.
  defp pushed?(node) do
    is_binary(node.session_metadata["docs_pushed_sha"]) or
      is_binary(docs_meta(node)["pushed_sha"])
  end

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

  defp resumable_nodes(project_id \\ nil) do
    node_ids(project_id)
    |> Enum.filter(fn node ->
      docs_state(node) in ["pending", "deferred"] and not pushed?(node)
    end)
  end

  defp enqueue_node(node, opts) do
    case code_commit_sha(node) do
      {:ok, _sha} -> enqueue(node.project_id, node.id, opts)
      {:error, _reason} -> :ok
    end
  end

  # Re-arm sync gating before a deferred job runs again, so a retry that is
  # still in flight is not pushed as the code-only node.
  defp maybe_requeue(%Node{} = node) do
    if docs_state(node) == "deferred" do
      update_node(node.id, fn current ->
        docs =
          current
          |> docs_meta()
          |> Map.put("state", "pending")
          |> Map.delete("error")

        Node.changeset(current, %{
          docs_state: :pending,
          session_metadata: Map.put(current.session_metadata, "docs", docs)
        })
      end)
    end

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
