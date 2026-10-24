defmodule Cadence.Daemon.NodesTest do
  use ExUnit.Case, async: false

  alias Cadence.Daemon.{Nodes, Repo}
  alias Cadence.Shared.{Node, Project}

  setup do
    project = insert_project()
    user_id = Application.get_env(:cadence_daemon, :local_user_id)
    %{project: project, user_id: user_id}
  end

  test "latest and list order by created_at then id", %{project: project, user_id: user_id} do
    old = insert_node(project.id, user_id, ~U[2026-01-01 00:00:00.000000Z])
    new = insert_node(project.id, user_id, ~U[2026-02-01 00:00:00.000000Z])

    assert Nodes.latest(project.id).id == new.id
    assert Enum.map(Nodes.list(project.id), & &1.id) == [new.id, old.id]
  end

  test "most_recent_by_user filters by author", %{project: project, user_id: user_id} do
    other_id = Ecto.UUID.generate()
    mine = insert_node(project.id, user_id, ~U[2026-01-01 00:00:00.000000Z])
    _other = insert_node(project.id, other_id, ~U[2026-02-01 00:00:00.000000Z])

    assert Nodes.most_recent_by_user(project.id, user_id).id == mine.id
    assert Nodes.most_recent_by_user(project.id, nil) == nil
  end

  test "preview prefers pinned, then functioning", %{project: project, user_id: user_id} do
    _new = insert_node(project.id, user_id, ~U[2026-03-01 00:00:00.000000Z])

    good =
      insert_node(project.id, user_id, ~U[2026-02-01 00:00:00.000000Z], flags: [:functioning])

    pinned = insert_node(project.id, user_id, ~U[2026-01-01 00:00:00.000000Z], pinned: true)

    assert Nodes.preview(project.id).id == pinned.id
    assert {:ok, _} = Repo.update(Node.changeset(Repo.get!(Node, pinned.id), %{pinned: false}))
    assert Nodes.preview(project.id).id == good.id
  end

  test "existing_ids returns only matching project nodes", %{
    project: project,
    user_id: user_id
  } do
    node = insert_node(project.id, user_id, ~U[2026-01-01 00:00:00.000000Z])
    other = insert_node(insert_project().id, user_id, ~U[2026-01-02 00:00:00.000000Z])

    assert Nodes.existing_ids(project.id, [node.id, other.id, "not-a-uuid"]) ==
             MapSet.new([node.id])

    assert Nodes.existing_ids(project.id, []) == MapSet.new()
    assert Nodes.existing_ids("not-a-uuid", [node.id]) == MapSet.new()
  end

  test "malformed project ids return empty results" do
    assert Nodes.latest("not-a-uuid") == nil
    assert Nodes.list("not-a-uuid") == []
    assert Nodes.preview("not-a-uuid") == nil
  end

  defp insert_project do
    %{
      name: "p",
      slug: "nodes-#{System.unique_integer([:positive])}",
      owner_id: Ecto.UUID.generate()
    }
    |> Project.changeset()
    |> Repo.insert!()
  end

  defp insert_node(project_id, user_id, created_at, opts \\ []) do
    %{
      project_id: project_id,
      git_commit_sha: String.duplicate("a", 40),
      flags: Keyword.get(opts, :flags, [:"in-progress"]),
      pinned: Keyword.get(opts, :pinned, false),
      message: "m",
      created_by: user_id,
      created_at: created_at,
      docs_state: :pending
    }
    |> Node.changeset()
    |> Repo.insert!()
  end
end
