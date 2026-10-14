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

    assert {:error, :not_found} = Session.switch(project.id, Ecto.UUID.generate())

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
end
