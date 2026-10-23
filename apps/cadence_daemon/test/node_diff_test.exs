defmodule Cadence.Daemon.NodeDiffTest do
  use ExUnit.Case, async: false

  alias Cadence.Daemon.{NodeDiff, ProjectLocation, Repo}
  alias Cadence.Shared.{GitStore, Node, Project}

  @author %{name: "cadence", email: "cadence@local"}

  setup do
    root = Path.join(System.tmp_dir!(), "cadence_diff_#{System.unique_integer([:positive])}")
    git_dir = Path.join(root, "git")
    File.mkdir_p!(git_dir)

    {:ok, project} = insert_project()
    insert_location(project.id, git_dir)

    git = GitStore.init(git_dir, bare: true)
    {c1, c2} = two_commits(git)

    root_node = insert_node(project.id, c1, [])
    child_node = insert_node(project.id, c2, [root_node.id])

    on_exit(fn -> File.rm_rf!(root) end)

    %{project: project, root_node: root_node, child_node: child_node}
  end

  test "diffs a node against its parent's file", %{
    project: project,
    root_node: root_node,
    child_node: child
  } do
    {:ok, payload} = NodeDiff.build(project.id, child.id)

    assert payload.node_id == child.id
    assert payload.base_node_id == root_node.id
    refute payload.truncated

    assert [file] = payload.files
    assert file.path == "a.txt"
    assert file.status == :modified

    lines = Map.new(file.lines, &{&1.kind, &1.text})
    assert lines[:ctx] == "hello"
    assert lines[:add] == "world"
  end

  test "a root node has no base and shows all content as added", %{
    project: project,
    root_node: root
  } do
    {:ok, payload} = NodeDiff.build(project.id, root.id)

    assert payload.base_node_id == nil
    assert [file] = payload.files
    assert Enum.all?(file.lines, &(&1.kind == :add))
  end

  test "returns :not_found for an unknown node or a node in another project",
       %{project: project, child_node: child} do
    assert {:error, :not_found} = NodeDiff.build(project.id, Ecto.UUID.generate())
    assert {:error, :not_found} = NodeDiff.build(project.id, "not-a-uuid")

    {:ok, other} = insert_project()
    assert {:error, :not_found} = NodeDiff.build(other.id, child.id)
  end

  test "returns :no_location when the project has no local git dir" do
    {:ok, project} = insert_project()
    node = insert_node(project.id, String.duplicate("a", 40), [])
    assert {:error, :no_location} = NodeDiff.build(project.id, node.id)
  end

  defp insert_project do
    %{name: "p", slug: "p-#{System.unique_integer([:positive])}", owner_id: Ecto.UUID.generate()}
    |> Project.changeset()
    |> Repo.insert()
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

  defp two_commits(git) do
    b1 = GitStore.write_blob(git, "hello\n")
    t1 = GitStore.write_tree(git, [entry("a.txt", b1)])
    c1 = GitStore.write_commit(git, t1, [], @author, "one")

    b2 = GitStore.write_blob(git, "hello\nworld\n")
    t2 = GitStore.write_tree(git, [entry("a.txt", b2)])
    c2 = GitStore.write_commit(git, t2, [c1], @author, "two")

    {c1, c2}
  end

  defp entry(name, ref), do: %{name: name, mode: "100644", type: :blob, ref: ref}
end
