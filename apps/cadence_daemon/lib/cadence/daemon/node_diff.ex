defmodule Cadence.Daemon.NodeDiff do
  @moduledoc """
  Builds a renderable diff for a single node against its parent.

  Resolves the node and its first parent (the base; `nil` for a root), reads
  both trees from the project's `Cadence.Shared.GitStore`, and hands the
  file-level changes to `Cadence.Shared.Diff` for line-level annotation.
  """

  alias Cadence.Daemon.{Env, ProjectLocation, Repo}
  alias Cadence.Shared.{Diff, GitStore, Node}

  @doc """
  Returns `{:ok, payload}` with `:node_id`, `:base_node_id`, `:truncated`, and
  `:files`, or `{:error, reason}` where reason is `:not_found` (node missing or
  not in the project), `:no_location`, or `:no_commit`.
  """
  @spec build(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, atom()}
  def build(project_id, node_id) do
    with {:ok, node} <- fetch_node(project_id, node_id),
         {:ok, git} <- open_git(project_id),
         {:ok, commit} <- read_commit(git, node.git_commit_sha) do
      old_tree = parent_tree(git, node.parents)

      diff =
        git
        |> GitStore.diff_trees(old_tree, commit.tree)
        |> Diff.files(
          max_files: Env.diff_max_files(),
          max_lines_per_file: Env.diff_max_lines_per_file()
        )

      {:ok,
       %{
         node_id: node.id,
         base_node_id: List.first(node.parents),
         truncated: diff.truncated,
         files: diff.files
       }}
    end
  end

  defp fetch_node(project_id, node_id) do
    case Repo.get(Node, node_id) do
      %Node{project_id: ^project_id} = node -> {:ok, node}
      _ -> {:error, :not_found}
    end
  end

  defp open_git(project_id) do
    case Repo.get(ProjectLocation, project_id) do
      nil -> {:error, :no_location}
      location -> {:ok, GitStore.open(location.git_dir, bare: true)}
    end
  end

  defp read_commit(git, sha) do
    case GitStore.read_commit(git, sha) do
      nil -> {:error, :no_commit}
      commit -> {:ok, commit}
    end
  end

  defp parent_tree(_git, []), do: nil

  defp parent_tree(git, [parent_id | _]) do
    case Repo.get(Node, parent_id) do
      nil ->
        nil

      parent ->
        case GitStore.read_commit(git, parent.git_commit_sha) do
          nil -> nil
          commit -> commit.tree
        end
    end
  end
end
