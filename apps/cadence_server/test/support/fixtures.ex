defmodule Cadence.ServerFixtures do
  @moduledoc """
  Small database fixtures for server context tests.

  Snapshot helpers write real Git objects into the project's bare store so
  read models and pages can be exercised end to end.
  """

  alias Cadence.Server.{ProjectGit, Proposals, Repo}
  alias Cadence.Server.Proposal
  alias Cadence.Shared.{GitStore, Membership, Node, Project}

  @doc "Insert a project owned by `owner_id`."
  def project(owner_id, attrs \\ %{}) do
    defaults = %{
      name: "Test Project",
      slug: "project-#{System.unique_integer([:positive, :monotonic])}",
      owner_id: owner_id
    }

    %Project{}
    |> Project.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  @doc "Insert a membership for `user_id` in `project`."
  def membership(project, user_id, role, attrs \\ %{}) do
    defaults = %{user_id: user_id, project_id: project.id, role: role}

    %Membership{}
    |> Membership.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  @doc "Insert a node belonging to `project`."
  def node_fixture(project, attrs \\ %{}) do
    defaults = %{
      project_id: project.id,
      git_commit_sha: String.duplicate("a", 40),
      created_by: project.owner_id,
      created_at: DateTime.utc_now(),
      docs_state: :pending,
      flags: [:"in-progress"],
      message: "node"
    }

    %Node{}
    |> Node.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  @doc """
  Commit `files` (a `path => content` map) into the project's store.

  Returns `%{commit: sha, tree: sha}`. `parents` are commit SHAs.
  """
  def snapshot_tree(project, files, message \\ "snapshot", parents \\ []) do
    repo = ProjectGit.init(project.id)
    tree = build_tree(repo, files)
    commit = GitStore.write_commit(repo, tree, parents, author(), message)

    %{commit: commit, tree: tree}
  end

  @doc "Like `snapshot_tree/4` but returns only the commit SHA."
  def snapshot(project, files, message \\ "snapshot", parents \\ []) do
    snapshot_tree(project, files, message, parents).commit
  end

  @doc "Insert a node whose snapshot contains `files`."
  def node_with_snapshot(project, files, attrs \\ %{}) do
    sha = snapshot(project, files, attrs[:message] || "snapshot")

    node_fixture(project, Map.merge(%{git_commit_sha: sha}, attrs))
  end

  @doc """
  Insert a proposal row directly, bypassing context checks.

  Read-model tests use this to build states the creation path forbids (for
  example, a parent from another project).
  """
  def proposal(attrs) do
    %Proposal{}
    |> Proposal.changeset(attrs)
    |> Repo.insert!()
  end

  @doc """
  Create a pending meld proposal for `proposer_id` via the context.

  `result` is the map returned by `snapshot_tree/4`. `attrs` override the
  defaults, so a bogus `meld_commit_sha` can model an unreplicated result.
  """
  def meld_proposal(project, proposer_id, parents, result, attrs \\ %{}) do
    ensure_membership(project, proposer_id)

    attrs =
      Map.merge(
        %{
          project_id: project.id,
          kind: :meld,
          parent_ids: Enum.map(parents, & &1.id),
          result_tree_sha: result.tree,
          meld_commit_sha: result.commit
        },
        attrs
      )

    case Proposals.create(%{id: proposer_id}, attrs) do
      {:ok, proposal} -> proposal
      {:error, reason} -> raise "meld_proposal/5 failed: #{inspect(reason)}"
    end
  end

  @doc "Create a pending promotion proposal for `proposer_id` via the context."
  def promotion_proposal(project, proposer_id, target_node) do
    ensure_membership(project, proposer_id)

    attrs = %{
      project_id: project.id,
      kind: :promotion,
      target_node_id: target_node.id
    }

    case Proposals.create(%{id: proposer_id}, attrs) do
      {:ok, proposal} -> proposal
      {:error, reason} -> raise "promotion_proposal/3 failed: #{inspect(reason)}"
    end
  end

  defp ensure_membership(project, user_id) do
    case Repo.get_by(Membership, user_id: user_id, project_id: project.id) do
      nil -> membership(project, user_id, :owner)
      _membership -> :ok
    end
  end

  defp build_tree(repo, files) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "cadence_fixture_snapshot_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(dir)

    try do
      Enum.each(files, fn {path, content} ->
        full = Path.join(dir, path)
        File.mkdir_p!(Path.dirname(full))
        File.write!(full, content)
      end)

      GitStore.build_tree(repo, dir)
    after
      File.rm_rf!(dir)
    end
  end

  defp author, do: %{name: "Fixture", email: "fixture@example.com"}
end
