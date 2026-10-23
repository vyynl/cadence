defmodule Cadence.Daemon.NodeDiff do
  @moduledoc """
  Builds a renderable diff for a single node against its parent.

  Resolves the node and its first parent (the base; `nil` for a root), reads
  both trees from the project's `Cadence.Shared.GitStore`, and hands the
  file-level changes to `Cadence.Shared.Diff` for line-level annotation.
  """

  alias Cadence.Daemon.{Env, NodeStore, Repo}
  alias Cadence.Shared.{Diff, GitStore, Node, UUID}

  @doc """
  Returns `{:ok, payload}` with `:node_id`, `:base_node_id`, `:truncated`, and
  `:files`, or `{:error, reason}` where reason is `:not_found` (node missing or
  not in the project), `:no_location`, or `:no_commit`.
  """
  @spec build(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, atom()}
  def build(project_id, node_id) do
    with {:ok, project_id} <- UUID.cast(project_id),
         {:ok, node_id} <- UUID.cast(node_id),
         {:ok, node} <- fetch_node(project_id, node_id),
         {:ok, git} <- NodeStore.open(project_id),
         {:ok, commit} <- NodeStore.read_commit(git, node.git_commit_sha),
         {:ok, old_tree} <- NodeStore.parent_tree(git, node.parents) do
      diff =
        git
        |> GitStore.diff_trees(old_tree, commit.tree)
        |> Diff.files(
          max_files: Env.diff_max_files(),
          max_lines_per_file: Env.diff_max_lines_per_file(),
          max_bytes: Env.diff_max_bytes()
        )

      {:ok,
       %{
         node_id: node.id,
         base_node_id: List.first(node.parents),
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
end
