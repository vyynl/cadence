defmodule Cadence.Daemon.DocDiff do
  @moduledoc """
  Builds the doc-only diff for a node (spec §9.4).

  A node with a queued doc job points at the follow-up docs commit (`C2`); the
  docs diff is `diff(C1.tree, C2.tree)` filtered to the paths the project
  schema allows. Nodes that predate doc automation fall back to their first
  logical parent's tree.

  Both commits are read from the local Git store, so this only works on the
  machine that generated the docs; the web UI shows the combined node diff
  instead.
  """

  alias Cadence.Daemon.{Env, NodeStore, ProjectLocation, Repo}
  alias Cadence.Daemon.Docs.SchemaSource
  alias Cadence.Shared.{Diff, GitStore, Node, UUID}

  @doc """
  Returns `{:ok, payload}` with `:node_id`, `:code_commit_sha`,
  `:docs_commit_sha`, `:truncated`, and `:files`.

  Errors: `:not_found` (unknown node/project), `:no_location`, `:no_commit`,
  `:no_docs_commit` (code-only, skipped docs, or an empty generation with no
  `C2`), `:no_schema`, and `:unreadable`.
  """
  @spec build(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, atom()}
  def build(project_id, node_id) do
    with {:ok, project_id} <- UUID.cast(project_id),
         {:ok, node_id} <- UUID.cast(node_id),
         {:ok, node} <- fetch_node(project_id, node_id),
         {:ok, git} <- NodeStore.open(project_id),
         {:ok, docs_sha} <- docs_commit_sha(node),
         {:ok, code_sha, old_tree} <- base_tree(git, node),
         {:ok, docs_commit} <- NodeStore.read_commit(git, docs_sha),
         {:ok, schema} <- load_schema(project_id) do
      diff =
        git
        |> GitStore.diff_trees(old_tree, docs_commit.tree)
        |> Enum.filter(&Cadence.Shared.Docs.Schema.allowed_path?(schema, &1.path))
        |> Diff.files(
          max_files: Env.diff_max_files(),
          max_lines_per_file: Env.diff_max_lines_per_file(),
          max_bytes: Env.diff_max_bytes()
        )

      {:ok,
       %{
         node_id: node.id,
         code_commit_sha: code_sha,
         docs_commit_sha: docs_sha,
         truncated: diff.truncated,
         files: diff.files
       }}
    else
      :error -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_node(project_id, node_id) do
    case Repo.get(Node, node_id) do
      %Node{project_id: ^project_id} = node -> {:ok, node}
      _ -> {:error, :not_found}
    end
  end

  defp docs_commit_sha(node) do
    meta = docs_meta(node)
    code_sha = meta["code_commit_sha"] || node.session_metadata["code_commit_sha"]
    docs_sha = meta["docs_commit_sha"]

    cond do
      meta["empty"] == true ->
        {:error, :no_docs_commit}

      is_binary(docs_sha) and docs_sha != code_sha ->
        {:ok, docs_sha}

      is_binary(docs_sha) ->
        # A no-op generation records no distinct C2 (§9.4).
        {:error, :no_docs_commit}

      node.docs_state == :current ->
        {:ok, node.git_commit_sha}

      true ->
        {:error, :no_docs_commit}
    end
  end

  defp base_tree(git, node) do
    case docs_meta(node)["code_commit_sha"] || node.session_metadata["code_commit_sha"] do
      sha when is_binary(sha) ->
        with {:ok, commit} <- NodeStore.read_commit(git, sha) do
          {:ok, sha, commit.tree}
        end

      _ ->
        with {:ok, old_tree} <- NodeStore.parent_tree(git, node.parents) do
          {:ok, nil, old_tree}
        end
    end
  end

  defp load_schema(project_id) do
    case Repo.get(ProjectLocation, project_id) do
      %ProjectLocation{work_dir: work_dir} ->
        case SchemaSource.load(work_dir) do
          {:ok, schema} -> {:ok, schema}
          :no_schema -> {:error, :no_schema}
          {:error, reason} -> {:error, reason}
        end

      nil ->
        {:error, :no_location}
    end
  end

  defp docs_meta(node) do
    case node.session_metadata do
      %{"docs" => %{} = docs} -> docs
      _ -> %{}
    end
  end
end
