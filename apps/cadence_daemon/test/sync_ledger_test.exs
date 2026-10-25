defmodule Cadence.Daemon.SyncLedgerTest do
  use ExUnit.Case, async: false

  alias Cadence.Daemon.{Repo, SyncCursor, SyncLedger, SyncPending}
  alias Cadence.Shared.{Node, Project}

  setup do
    project = insert_project()
    %{project: project}
  end

  test "enqueue is idempotent and pending is scoped by project", %{project: project} do
    node = insert_node(project.id, ~U[2026-10-23 12:00:00.000000Z])

    SyncLedger.enqueue(project.id, node.id)
    SyncLedger.enqueue(project.id, node.id)

    assert Enum.map(SyncLedger.pending(project.id), & &1.id) == [node.id]
    assert SyncLedger.pending(Ecto.UUID.generate()) == []
    assert SyncLedger.pending("not-a-uuid") == []
  end

  test "pending orders parents before children", %{project: project} do
    parent = insert_node(project.id, ~U[2026-10-23 12:00:00.000000Z])
    child = insert_node(project.id, ~U[2026-10-23 12:01:00.000000Z], [parent.id])

    # Enqueue out of order; the ledger must still order by node creation.
    SyncLedger.enqueue(project.id, child.id)
    SyncLedger.enqueue(project.id, parent.id)

    assert Enum.map(SyncLedger.pending(project.id), & &1.id) == [parent.id, child.id]
  end

  test "pushable selects parents first and blocks children of backed-off parents", %{
    project: project
  } do
    parent = insert_node(project.id, ~U[2026-10-23 12:00:00.000000Z])
    child = insert_node(project.id, ~U[2026-10-23 12:01:00.000000Z], [parent.id])
    independent = insert_node(project.id, ~U[2026-10-23 12:02:00.000000Z])

    Enum.each([parent, child, independent], &SyncLedger.enqueue(project.id, &1.id))

    assert node_ids(SyncLedger.pushable(project.id, nil, 10)) ==
             [parent.id, child.id, independent.id]

    now = DateTime.add(DateTime.utc_now(), 1, :second)

    future = DateTime.add(now, 3_600, :second)
    assert {:ok, _pending} = SyncLedger.mark_failed(parent.id, :boom, future)

    assert node_ids(SyncLedger.pushable(project.id, now, 10)) == [independent.id]

    assert node_ids(SyncLedger.pushable(project.id, future, 10)) ==
             [parent.id, child.id, independent.id]
  end

  test "pushable honors the limit without skipping a parent", %{project: project} do
    parent = insert_node(project.id, ~U[2026-10-23 12:00:00.000000Z])
    child = insert_node(project.id, ~U[2026-10-23 12:01:00.000000Z], [parent.id])
    SyncLedger.enqueue(project.id, parent.id)
    SyncLedger.enqueue(project.id, child.id)

    assert node_ids(SyncLedger.pushable(project.id, nil, 1)) == [parent.id]
    assert SyncLedger.pushable(project.id, nil, 0) == []
    assert SyncLedger.pushable("not-a-uuid", nil, 10) == []
  end

  test "marks pushed nodes and clears them from the queue", %{project: project} do
    a = insert_node(project.id, ~U[2026-10-23 12:00:00.000000Z])
    b = insert_node(project.id, ~U[2026-10-23 12:01:00.000000Z])

    SyncLedger.enqueue(project.id, a.id)
    SyncLedger.enqueue(project.id, b.id)

    assert :ok = SyncLedger.mark_pushed([a.id, b.id])
    assert SyncLedger.pending(project.id) == []
  end

  test "failed pushes increment attempts, store the error, and honor backoff",
       %{project: project} do
    node = insert_node(project.id, ~U[2026-10-23 12:00:00.000000Z])
    SyncLedger.enqueue(project.id, node.id)

    future = DateTime.add(DateTime.utc_now(), 3_600, :second)
    assert {:ok, _pending} = SyncLedger.mark_failed(node.id, {:http, 500}, future)

    stored = Repo.get!(SyncPending, node.id)
    assert stored.attempts == 1
    assert stored.last_error =~ "http"
    assert SyncLedger.pending(project.id) |> Enum.map(& &1.id) == [node.id]
    assert SyncLedger.due_pending(project.id) == []
    refute project.id in SyncLedger.pending_projects()

    past = DateTime.add(DateTime.utc_now(), -1, :second)
    assert {:ok, _pending} = SyncLedger.mark_failed(node.id, :network, past)
    assert Repo.get!(SyncPending, node.id).attempts == 2
    assert SyncLedger.due_pending(project.id) |> Enum.map(& &1.id) == [node.id]
    assert project.id in SyncLedger.pending_projects()
  end

  test "cursor round-trips and rejects invalid values", %{project: project} do
    assert SyncLedger.cursor(project.id) == nil
    assert {:ok, %SyncCursor{cursor: "12"}} = SyncLedger.put_cursor(project.id, "12")
    assert SyncLedger.cursor(project.id) == "12"
    assert {:ok, %SyncCursor{cursor: "13"}} = SyncLedger.put_cursor(project.id, "13")
    assert SyncLedger.cursor(project.id) == "13"

    assert {:error, :invalid_cursor} = SyncLedger.put_cursor(project.id, nil)
    assert {:error, :invalid_uuid} = SyncLedger.put_cursor("nope", "1")
  end

  test "preference state round-trips through push, remote, and error", %{project: project} do
    assert SyncLedger.preferences_state(project.id) == nil

    first = DateTime.utc_now()
    assert {:ok, preference} = SyncLedger.mark_preferences_pushed(project.id, first)
    assert preference.pushed_updated_at == first
    assert preference.remote_updated_at == first

    assert SyncLedger.preferences_state(project.id) == %{
             pushed_updated_at: first,
             remote_updated_at: first,
             last_error: nil
           }

    second = DateTime.add(first, 1, :second)
    assert {:ok, _preference} = SyncLedger.mark_preferences_remote(project.id, second)

    assert %{pushed_updated_at: ^second, remote_updated_at: ^second} =
             SyncLedger.preferences_state(project.id)

    assert {:ok, _preference} = SyncLedger.mark_preferences_error(project.id, {:http, 500})

    assert %{pushed_updated_at: ^second, remote_updated_at: ^second, last_error: error} =
             SyncLedger.preferences_state(project.id)

    assert error =~ "http"
  end

  test "preference errors are bounded and invalid versions are rejected", %{project: project} do
    assert {:ok, preference} =
             SyncLedger.mark_preferences_error(project.id, String.duplicate("x", 5_000))

    assert String.length(preference.last_error) <= 1_000

    assert {:error, :invalid_uuid} =
             SyncLedger.mark_preferences_pushed("nope", DateTime.utc_now())

    assert {:error, :invalid_preference_state} =
             SyncLedger.mark_preferences_pushed(project.id, nil)
  end

  test "preference changes are harmless before sync is configured", %{project: project} do
    assert :ok = SyncLedger.preferences_changed(project.id)
    assert :ok = SyncLedger.preferences_changed("not-a-uuid")
  end

  test "server user id round-trips and rejects invalid values" do
    user_id = Ecto.UUID.generate()

    assert {:ok, ^user_id} = SyncLedger.put_server_user_id(user_id)
    assert SyncLedger.server_user_id() == user_id
    assert {:error, :invalid_uuid} = SyncLedger.put_server_user_id("nope")
  end

  test "provisioned marker round-trips and clears", %{project: project} do
    refute SyncLedger.provisioned?(project.id)
    assert :ok = SyncLedger.mark_provisioned(project.id)
    assert SyncLedger.provisioned?(project.id)
    assert :ok = SyncLedger.clear_provisioned(project.id)
    refute SyncLedger.provisioned?(project.id)

    assert {:error, :invalid_uuid} = SyncLedger.mark_provisioned("nope")
    assert {:error, :invalid_uuid} = SyncLedger.clear_provisioned("nope")
  end

  test "attempts reports queued node attempts", %{project: project} do
    node = insert_node(project.id, ~U[2026-10-23 12:00:00.000000Z])
    assert SyncLedger.attempts(node.id) == nil

    SyncLedger.enqueue(project.id, node.id)
    assert SyncLedger.attempts(node.id) == 0

    assert {:ok, _} =
             SyncLedger.mark_failed(node.id, :boom, DateTime.add(DateTime.utc_now(), 60, :second))

    assert SyncLedger.attempts(node.id) == 1
  end

  test "rehydrate backfills existing local nodes once", %{project: project} do
    node = insert_node(project.id, ~U[2026-10-23 12:00:00.000000Z])

    assert :ok = SyncLedger.rehydrate(force: true)
    assert project.id |> SyncLedger.pending() |> Enum.map(& &1.id) == [node.id]

    assert :ok = SyncLedger.rehydrate()
    assert project.id |> SyncLedger.pending() |> Enum.map(& &1.id) == [node.id]
  end

  test "mark_failed returns not_found for an unknown pending node" do
    assert {:error, :not_found} =
             SyncLedger.mark_failed(Ecto.UUID.generate(), :boom, DateTime.utc_now())

    assert {:error, :invalid_uuid} =
             SyncLedger.mark_failed("nope", :boom, DateTime.utc_now())
  end

  defp node_ids(nodes), do: Enum.map(nodes, & &1.id)

  defp insert_project do
    %{
      name: "p",
      slug: "ledger-#{System.unique_integer([:positive])}",
      owner_id: Ecto.UUID.generate()
    }
    |> Project.changeset()
    |> Repo.insert!()
  end

  defp insert_node(project_id, created_at, parents \\ []) do
    %{
      project_id: project_id,
      git_commit_sha: String.duplicate("a", 40),
      parents: parents,
      flags: [:"in-progress"],
      message: "m",
      created_by: Application.get_env(:cadence_daemon, :local_user_id),
      created_at: created_at,
      docs_state: :pending
    }
    |> Node.changeset()
    |> Repo.insert!()
  end
end
