defmodule Cadence.Daemon.NodeStore do
  @moduledoc """
  Read access to a project's on-disk Git object store.

  `Cadence.Daemon.CommitQueue` owns writes through `GitStore`; this module
  centralizes the read paths used by the diff/message workers so they share
  location lookup and first-parent resolution.
  """

  alias Cadence.Daemon.{ProjectLocation, Repo}
  alias Cadence.Shared.{GitStore, Node, UUID}

  @doc "Opens the project's store, or returns `{:error, :no_location}`."
  @spec open(Ecto.UUID.t()) :: {:ok, GitStore.t()} | {:error, :no_location}
  def open(project_id) do
    with {:ok, project_id} <- UUID.cast(project_id),
         %ProjectLocation{} = location <- Repo.get(ProjectLocation, project_id) do
      {:ok, GitStore.open(location.git_dir, bare: true)}
    else
      _ -> {:error, :no_location}
    end
  end

  @doc "Reads a commit from the store, or returns `{:error, :no_commit}`."
  @spec read_commit(GitStore.t(), String.t()) ::
          {:ok, GitStore.commit()} | {:error, :no_commit}
  def read_commit(git, sha) do
    case GitStore.read_commit(git, sha) do
      nil -> {:error, :no_commit}
      commit -> {:ok, commit}
    end
  end

  @doc """
  Resolves the tree of a node's first parent, or `{:ok, nil}` for a root or a
  missing parent.
  """
  @spec parent_tree(GitStore.t(), [Ecto.UUID.t()]) :: {:ok, String.t() | nil}
  def parent_tree(_git, []), do: {:ok, nil}

  def parent_tree(git, [parent_id | _]) do
    case Repo.get(Node, parent_id) do
      nil ->
        {:ok, nil}

      parent ->
        case read_commit(git, parent.git_commit_sha) do
          {:ok, commit} -> {:ok, commit.tree}
          {:error, :no_commit} -> {:ok, nil}
        end
    end
  end
end
