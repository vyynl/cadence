defmodule Cadence.Daemon.NodeStoreTest do
  use ExUnit.Case, async: false

  alias Cadence.Daemon.{NodeStore, ProjectLocation, Repo}
  alias Cadence.Shared.{GitStore, Node, Project}

  @author %{name: "cadence", email: "cadence@local"}

  setup do
    root = Path.join(System.tmp_dir!(), "cadence_nodestore_#{System.unique_integer([:positive])}")
    git_dir = Path.join(root, "git")
    File.mkdir_p!(git_dir)
    on_exit(fn -> File.rm_rf!(root) end)

    project = insert_project()
    insert_location(project.id, git_dir)
    git = GitStore.init(git_dir, bare: true)

    root_tree = GitStore.write_tree(git, [])
    root_sha = GitStore.write_commit(git, root_tree, [], @author, "root")
    child_tree = GitStore.write_tree(git, [])
    child_sha = GitStore.write_commit(git, child_tree, [root_sha], @author, "child")

    root_node = insert_node(project.id, root_sha, [])
    child_node = insert_node(project.id, child_sha, [root_node.id])

    %{
      project: project,
      git: git,
      root_node: root_node,
      child_node: child_node,
      root_tree: root_tree,
      child_tree: child_tree
    }
  end

  test "opens the project store and reads commits/trees", %{
    project: project,
    root_node: root,
    child_node: child,
    root_tree: root_tree,
    child_tree: child_tree
  } do
    assert {:ok, git} = NodeStore.open(project.id)
    assert {:ok, %{tree: ^root_tree}} = NodeStore.read_commit(git, root.git_commit_sha)
    assert {:ok, %{tree: ^child_tree}} = NodeStore.read_commit(git, child.git_commit_sha)
    assert {:ok, nil} = NodeStore.parent_tree(git, root.parents)
    assert {:ok, ^root_tree} = NodeStore.parent_tree(git, child.parents)
  end

  test "returns :no_location for unknown or malformed projects" do
    assert {:error, :no_location} = NodeStore.open(Ecto.UUID.generate())
    assert {:error, :no_location} = NodeStore.open("not-a-uuid")
  end

  test "returns :no_commit for a missing commit", %{project: project} do
    assert {:ok, git} = NodeStore.open(project.id)
    assert {:error, :no_commit} = NodeStore.read_commit(git, String.duplicate("0", 40))
  end

  defp insert_project do
    %{
      name: "p",
      slug: "store-#{System.unique_integer([:positive])}",
      owner_id: Ecto.UUID.generate()
    }
    |> Project.changeset()
    |> Repo.insert!()
  end

  defp insert_location(project_id, git_dir) do
    %ProjectLocation{}
    |> ProjectLocation.changeset(%{
      project_id: project_id,
      work_dir: git_dir,
      git_dir: git_dir,
      created_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp insert_node(project_id, sha, parents) do
    %{
      project_id: project_id,
      git_commit_sha: sha,
      parents: parents,
      flags: [:"in-progress"],
      message: "m",
      created_by: Application.get_env(:cadence_daemon, :local_user_id),
      created_at: DateTime.utc_now(),
      docs_state: :pending
    }
    |> Node.changeset()
    |> Repo.insert!()
  end
end
