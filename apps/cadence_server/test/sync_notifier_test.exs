defmodule Cadence.Server.SyncNotifierTest do
  use ExUnit.Case, async: false

  import Cadence.ServerFixtures

  alias Cadence.Server.{Repo, SyncNotifier}

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  test "wakes every project member's own topic and no one else" do
    owner = Ecto.UUID.generate()
    approver = Ecto.UUID.generate()
    viewer = Ecto.UUID.generate()
    stranger = Ecto.UUID.generate()
    project = project(owner)
    membership(project, owner, :owner)
    membership(project, approver, :trusted, %{approver: true})
    membership(project, viewer, :viewer)

    for user_id <- [owner, approver, viewer, stranger] do
      subscribe_as(user_id)
    end

    assert SyncNotifier.project_changed(project.id) == :ok

    for member <- [owner, approver, viewer] do
      assert_receive {^member, {:sync_available, project_id}}
      assert project_id == project.id
    end

    refute_receive {^stranger, {:sync_available, _project_id}}
  end

  test "user_changed wakes only that user" do
    user = Ecto.UUID.generate()
    other = Ecto.UUID.generate()
    project = project(user)
    membership(project, user, :owner)
    membership(project, other, :viewer)

    for user_id <- [user, other] do
      subscribe_as(user_id)
    end

    assert SyncNotifier.user_changed(user, project.id) == :ok

    assert_receive {^user, {:sync_available, project_id}}
    assert project_id == project.id
    refute_receive {^other, {:sync_available, _project_id}}
  end

  test "unknown and malformed ids are a silent no-op" do
    user = Ecto.UUID.generate()
    subscribe_as(user)

    assert SyncNotifier.project_changed(Ecto.UUID.generate()) == :ok
    assert SyncNotifier.project_changed("not-a-uuid") == :ok
    assert SyncNotifier.user_changed(user, "not-a-uuid") == :ok
    refute_receive {^user, {:sync_available, _project_id}}
  end

  # Subscribe from a separate process so the assertion proves *which* topic was
  # broadcast on, not just how many broadcasts happened.
  defp subscribe_as(user_id) do
    parent = self()
    ref = make_ref()

    spawn_link(fn ->
      Phoenix.PubSub.subscribe(Cadence.Server.PubSub, "sync:user:#{user_id}")
      send(parent, {ref, :subscribed})

      receive do
        message -> send(parent, {user_id, message})
      end
    end)

    assert_receive {^ref, :subscribed}
  end
end
