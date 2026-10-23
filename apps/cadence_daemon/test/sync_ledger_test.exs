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
