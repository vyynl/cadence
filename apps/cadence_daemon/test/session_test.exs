defmodule Cadence.Daemon.SessionTest do
  use ExUnit.Case, async: false

  alias Cadence.Daemon.{Repo, Session}
  alias Cadence.Shared.{Membership, Node, Project}

  setup do
    user_id = Application.get_env(:cadence_daemon, :local_user_id)
    project = project_fixture(user_id)
    %{project: project, user_id: user_id}
  end

  test "ensure_membership! creates an owner membership and is idempotent",
       %{project: project, user_id: user_id} do
    membership = Session.ensure_membership!(project.id)
    assert membership.user_id == user_id
    assert membership.role == :owner
    assert membership.active_heads == []
    assert membership.preferences_updated_at == nil

    assert Session.ensure_membership!(project.id).user_id == user_id
  end

  test "current_node returns nil until a pointer is set", %{project: project} do
    Session.ensure_membership!(project.id)
    assert Session.current_node(project.id) == nil
  end

  test "switch moves the pointer and rejects foreign nodes", %{project: project} do
    Session.ensure_membership!(project.id)
    node = node_fixture(project.id)

    assert {:ok, membership} = Session.switch(project.id, node.id)
    assert membership.session_pointer == node.id
    assert membership.preferences_updated_at

    assert {:error, :not_found} = Session.switch(project.id, Ecto.UUID.generate())
    assert {:error, :not_found} = Session.switch(project.id, "not-a-uuid")

    other = project_fixture(project.owner_id)
    assert {:error, :not_found} = Session.switch(project.id, node_fixture(other.id).id)
  end

  test "spawn_after advances the pointer and adds the parent to active heads",
       %{project: project} do
    Session.ensure_membership!(project.id)
    parent = node_fixture(project.id)
    {:ok, _} = Session.switch(project.id, parent.id)

    child = node_fixture(project.id)
    {:ok, membership} = Session.spawn_after(project.id, parent, child)

    assert membership.session_pointer == child.id
    assert parent.id in membership.active_heads
    assert membership.preferences_updated_at
  end

  test "commit_after advances the pointer and drops superseded parents",
       %{project: project, user_id: user_id} do
    Session.ensure_membership!(project.id)
    parent = node_fixture(project.id)

    membership = Repo.get_by(Membership, user_id: user_id, project_id: project.id)
    {:ok, _} = Membership.changeset(membership, %{active_heads: [parent.id]}) |> Repo.update()

    child = node_fixture(project.id, [parent.id])
    {:ok, membership} = Session.commit_after(project.id, child)

    assert membership.session_pointer == child.id
    refute parent.id in membership.active_heads
    assert membership.preferences_updated_at
  end

  test "preference versions advance across mutations", %{project: project} do
    Session.ensure_membership!(project.id)
    first = node_fixture(project.id)

    {:ok, switched} = Session.switch(project.id, first.id)
    second = node_fixture(project.id, [first.id])
    {:ok, committed} = Session.commit_after(project.id, second)
    third = node_fixture(project.id, [second.id])
    {:ok, spawned} = Session.spawn_after(project.id, second, third)

    assert DateTime.compare(committed.preferences_updated_at, switched.preferences_updated_at) ==
             :gt

    assert DateTime.compare(spawned.preferences_updated_at, committed.preferences_updated_at) ==
             :gt
  end

  test "state returns read-only defaults without a membership",
       %{project: project, user_id: user_id} do
    assert %{user_id: ^user_id, session_pointer: nil, active_heads: []} =
             Session.state(project.id)
  end

  test "state reflects the pointer and active heads", %{project: project} do
    Session.ensure_membership!(project.id)
    parent = node_fixture(project.id)
    child = node_fixture(project.id, [parent.id])
    {:ok, _} = Session.spawn_after(project.id, parent, child)

    assert %{session_pointer: child_id, active_heads: [parent_id]} = Session.state(project.id)
    assert child_id == child.id
    assert parent_id == parent.id
  end

  test "anchor_node returns the session pointer when set", %{project: project} do
    Session.ensure_membership!(project.id)
    parent = node_fixture(project.id)
    _child = node_fixture(project.id, [parent.id])
    {:ok, _} = Session.switch(project.id, parent.id)

    assert Session.anchor_node(project.id).id == parent.id
  end

  test "anchor_node falls back to the local user's most-recent node", %{project: project} do
    mine = node_fixture(project.id)
    Session.ensure_membership!(project.id)

    assert Session.anchor_node(project.id).id == mine.id
  end

  test "anchor_node prefers the preview node when the user has none", %{project: project} do
    other = other_user_node(project.id, pinned: true)
    Session.ensure_membership!(project.id)

    assert Session.anchor_node(project.id).id == other.id
  end

  test "anchor_node is nil for an empty project", %{project: project} do
    assert Session.anchor_node(project.id) == nil
  end

  defp project_fixture(owner_id) do
    %{name: "p", slug: "p-#{System.unique_integer([:positive])}", owner_id: owner_id}
    |> Project.changeset()
    |> Repo.insert!()
  end

  defp node_fixture(project_id, parents \\ []) do
    %{
      project_id: project_id,
      git_commit_sha: String.duplicate("a", 40),
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

  defp other_user_node(project_id, opts) do
    %{
      project_id: project_id,
      git_commit_sha: String.duplicate("b", 40),
      parents: [],
      flags: [:"in-progress"],
      pinned: Keyword.get(opts, :pinned, false),
      message: "m",
      created_by: Ecto.UUID.generate(),
      created_at: DateTime.utc_now(),
      docs_state: :pending
    }
    |> Node.changeset()
    |> Repo.insert!()
  end
end
