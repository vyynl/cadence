defmodule Cadence.Daemon.SyncTest do
  use ExUnit.Case, async: false

  alias Cadence.Daemon.{
    CommitQueue,
    Env,
    Nodes,
    ProjectLocation,
    Repo,
    Session,
    Sync,
    SyncLedger,
    SyncPending,
    SyncSocket,
    SyncWorker
  }

  alias Cadence.Daemon.TestSyncServer
  alias Cadence.Shared.{GitStore, Membership, Node, Project}
  alias Cadence.Shared.Sync.NodeCodec

  @server_user "11111111-1111-4111-8111-111111111111"
  @token "cad-test-token"
  @author %{name: "Sync Test", email: "sync@example.com"}

  setup do
    root = Path.join(System.tmp_dir!(), "cadence_sync_#{System.unique_integer([:positive])}")
    work_dir = Path.join(root, "work")
    git_dir = Path.join(root, "git")
    File.mkdir_p!(work_dir)

    project = insert_project()
    insert_location(project.id, work_dir, git_dir)

    {:ok, server} = TestSyncServer.start(@server_user)
    TestSyncServer.stub(__MODULE__, server)
    Req.Test.set_req_test_to_shared()
    {:ok, _} = SyncLedger.put_server_user_id(@server_user)

    on_exit(fn ->
      _ = :sys.get_state(SyncLedger)
      Application.put_env(:cadence_daemon, :sync_enabled, false)
      wait_for_sync_idle()
      Req.Test.set_req_test_to_private()
      clear_sync_config()
      File.rm_rf(root)
    end)

    %{
      project: project,
      work_dir: work_dir,
      git_dir: git_dir,
      server: server
    }
  end

  test "commits and spawns enqueue pending sync rows", %{
    project: project,
    work_dir: work_dir,
    git_dir: git_dir
  } do
    queue = start_queue(project, work_dir, git_dir)

    {:ok, first} = commit(queue, work_dir, "first")
    assert eventually(fn -> pending?(project.id, first.id) end)

    {:ok, spawn} = CommitQueue.spawn(queue, "explore")
    assert eventually(fn -> pending?(project.id, spawn.id) end)
  end

  test "sync provisions, pushes, clears pending, and is idempotent", %{
    project: project,
    work_dir: work_dir,
    git_dir: git_dir,
    server: server
  } do
    queue = start_queue(project, work_dir, git_dir)
    {:ok, node} = commit(queue, work_dir, "first")
    assert eventually(fn -> pending?(project.id, node.id) end)

    configure_sync()

    assert :ok = Sync.sync(project.id)
    assert SyncLedger.pending(project.id) == []
    assert SyncLedger.cursor(project.id) == "1"
    assert TestSyncServer.project(server, project.id)["id"] == project.id

    assert [wire] = TestSyncServer.nodes(server)
    assert wire["id"] == node.id
    assert wire["created_by"] == @server_user
    assert wire["message"] == "first"
    assert wire["git_objects"] != []

    assert :ok = Sync.sync(project.id)
    assert length(TestSyncServer.nodes(server)) == 1
    assert length(Nodes.list(project.id)) == 1
  end

  test "pull imports a remote DAG into a clean local store", %{
    project: project,
    git_dir: git_dir,
    server: server
  } do
    {wire, commit_sha, expected} = remote_node(project.id)

    TestSyncServer.seed_node(server, project.id, wire)
    configure_sync()

    assert :ok = Sync.sync(project.id)
    assert [node] = Nodes.list(project.id)
    assert node.id == wire["id"]
    assert node.git_commit_sha == commit_sha
    assert node.created_by == Env.local_user_id()
    assert SyncLedger.cursor(project.id) == "1"

    git = GitStore.open(git_dir, bare: true)
    dest = Path.join(Path.dirname(git_dir), "checkout")
    :ok = GitStore.checkout(git, commit_sha, dest)
    assert File.read!(Path.join(dest, "README.md")) == expected

    # A second pull is idempotent and does not duplicate the node.
    assert :ok = Sync.sync(project.id)
    assert length(Nodes.list(project.id)) == 1
  end

  test "pull applies a server-side pin to an existing node", %{
    project: project,
    server: server
  } do
    {wire, commit_sha, _expected} = remote_node(project.id)
    local = insert_node(project.id, wire["id"], commit_sha, [])
    refute local.pinned

    TestSyncServer.seed_node(server, project.id, Map.put(wire, "pinned", true))
    configure_sync()

    assert :ok = Sync.sync(project.id)

    # Only `pinned` is server-mutable; the snapshot metadata stays local.
    assert %{pinned: true, git_commit_sha: ^commit_sha, message: "local"} =
             Repo.get(Node, wire["id"])
  end

  test "pull conflict aborts before advancing the cursor", %{
    project: project,
    server: server
  } do
    {wire, _commit_sha, _expected} = remote_node(project.id)
    local = insert_node(project.id, wire["id"], String.duplicate("a", 40), [])

    TestSyncServer.seed_node(server, project.id, wire)
    configure_sync()

    assert {:error, {:node_conflict, id}} = Sync.sync(project.id)
    assert id == local.id
    assert SyncLedger.cursor(project.id) == nil
  end

  test "push_preferences sends a dirty local version and stops when clean", %{
    project: project,
    work_dir: work_dir,
    git_dir: git_dir,
    server: server
  } do
    queue = start_queue(project, work_dir, git_dir)
    {:ok, node} = commit(queue, work_dir, "first")
    assert eventually(fn -> pending?(project.id, node.id) end)

    configure_sync()
    assert :ok = Sync.ensure_project(project.id)

    local = membership(project.id)
    assert local.preferences_updated_at

    assert :ok = Sync.push_preferences(project.id)

    stored = TestSyncServer.preferences(server, project.id)
    assert stored["session_pointer"] == node.id
    assert stored["updated_at"] == DateTime.to_iso8601(local.preferences_updated_at)

    assert %{pushed_updated_at: pushed} = SyncLedger.preferences_state(project.id)
    assert DateTime.compare(pushed, local.preferences_updated_at) == :eq

    TestSyncServer.fail_next(server, 500)
    assert :ok = Sync.push_preferences(project.id)
  end

  test "push_preferences applies a newer server value and does not echo", %{
    project: project,
    work_dir: work_dir,
    git_dir: git_dir,
    server: server
  } do
    queue = start_queue(project, work_dir, git_dir)
    {:ok, first} = commit(queue, work_dir, "first")
    {:ok, _second} = commit(queue, work_dir, "second")

    configure_sync()
    assert :ok = Sync.ensure_project(project.id)

    local = membership(project.id)
    remote_version = DateTime.add(local.preferences_updated_at, 60, :second)
    unknown = Ecto.UUID.generate()

    TestSyncServer.seed_preferences(server, project.id, %{
      "active_heads" => [first.id, unknown],
      "session_pointer" => first.id,
      "updated_at" => DateTime.to_iso8601(remote_version)
    })

    assert :ok = Sync.push_preferences(project.id)

    applied = membership(project.id)
    assert applied.session_pointer == first.id
    assert applied.active_heads == [first.id]
    assert DateTime.compare(applied.preferences_updated_at, remote_version) == :eq

    assert %{pushed_updated_at: pushed, remote_updated_at: remote} =
             SyncLedger.preferences_state(project.id)

    assert DateTime.compare(pushed, remote_version) == :eq
    assert DateTime.compare(remote, remote_version) == :eq

    TestSyncServer.fail_next(server, 500)
    assert :ok = Sync.push_preferences(project.id)
  end

  test "pull applies newer remote preferences after importing the node", %{
    project: project,
    server: server
  } do
    Session.ensure_membership!(project.id)
    {wire, _commit_sha, _expected} = remote_node(project.id)
    TestSyncServer.seed_node(server, project.id, wire)

    version = DateTime.add(DateTime.utc_now(), 60, :second)
    unknown = Ecto.UUID.generate()

    TestSyncServer.seed_preferences(server, project.id, %{
      "active_heads" => [wire["id"], unknown, wire["id"]],
      "session_pointer" => wire["id"],
      "updated_at" => DateTime.to_iso8601(version)
    })

    configure_sync()
    assert :ok = Sync.ensure_project(project.id)
    assert :ok = Sync.pull(project.id)

    applied = membership(project.id)
    assert applied.session_pointer == wire["id"]
    assert applied.active_heads == [wire["id"]]
    assert DateTime.compare(applied.preferences_updated_at, version) == :eq
  end

  test "pull filters unknown active heads and preserves an unknown pointer", %{
    project: project,
    server: server
  } do
    Session.ensure_membership!(project.id)
    local = insert_node(project.id, Ecto.UUID.generate(), String.duplicate("c", 40), [])
    assert {:ok, _membership} = Session.switch(project.id, local.id)

    version = DateTime.add(DateTime.utc_now(), 60, :second)
    unknown = Ecto.UUID.generate()

    TestSyncServer.seed_preferences(server, project.id, %{
      "active_heads" => [local.id, unknown],
      "session_pointer" => unknown,
      "updated_at" => DateTime.to_iso8601(version)
    })

    configure_sync()
    assert :ok = Sync.ensure_project(project.id)
    assert :ok = Sync.pull(project.id)

    applied = membership(project.id)
    assert applied.session_pointer == local.id
    assert applied.active_heads == [local.id]
    assert DateTime.compare(applied.preferences_updated_at, version) == :eq
  end

  test "pull ignores older remote preferences", %{project: project, server: server} do
    Session.ensure_membership!(project.id)
    local = insert_node(project.id, Ecto.UUID.generate(), String.duplicate("d", 40), [])
    assert {:ok, _membership} = Session.switch(project.id, local.id)
    local = membership(project.id)

    older = DateTime.add(local.preferences_updated_at, -1, :second)

    TestSyncServer.seed_preferences(server, project.id, %{
      "active_heads" => [],
      "session_pointer" => Ecto.UUID.generate(),
      "updated_at" => DateTime.to_iso8601(older)
    })

    configure_sync()
    assert :ok = Sync.ensure_project(project.id)
    assert :ok = Sync.pull(project.id)

    unchanged = membership(project.id)
    assert unchanged.session_pointer == local.session_pointer
    assert unchanged.active_heads == local.active_heads
    assert DateTime.compare(unchanged.preferences_updated_at, local.preferences_updated_at) == :eq
  end

  test "apply_remote_preferences rejects malformed payloads", %{project: project} do
    assert :ok = Sync.apply_remote_preferences(project.id, nil)

    assert {:error, :invalid_preferences} =
             Sync.apply_remote_preferences(project.id, %{
               "active_heads" => [],
               "session_pointer" => nil,
               "updated_at" => "not-a-timestamp"
             })

    assert {:error, :invalid_preferences} =
             Sync.apply_remote_preferences(project.id, %{
               "active_heads" => ["not-a-uuid"],
               "session_pointer" => nil,
               "updated_at" => DateTime.to_iso8601(DateTime.utc_now())
             })
  end

  test "local preferences round-trip and apply to a cleared session", %{
    project: project,
    work_dir: work_dir,
    git_dir: git_dir,
    server: server
  } do
    queue = start_queue(project, work_dir, git_dir)
    {:ok, node} = commit(queue, work_dir, "first")

    configure_sync()
    assert :ok = Sync.sync(project.id)

    stored = TestSyncServer.preferences(server, project.id)
    assert stored["session_pointer"] == node.id

    cleared = membership(project.id)

    {:ok, _membership} =
      cleared
      |> Membership.changeset(%{
        active_heads: [],
        session_pointer: nil,
        preferences_updated_at: nil
      })
      |> Repo.update()

    assert :ok = Sync.sync(project.id)

    restored = membership(project.id)
    assert restored.session_pointer == node.id
    assert restored.preferences_updated_at
  end

  test "offline preference changes flush once sync is configured", %{
    project: project,
    work_dir: work_dir,
    git_dir: git_dir,
    server: server
  } do
    queue = start_queue(project, work_dir, git_dir)
    {:ok, node} = commit(queue, work_dir, "first")

    local = membership(project.id)
    assert local.preferences_updated_at
    assert SyncLedger.preferences_state(project.id) == nil

    configure_sync()
    assert :ok = Sync.sync(project.id)

    assert TestSyncServer.preferences(server, project.id)["session_pointer"] == node.id
  end

  test "two machines converge on a shared session pointer and active heads", %{
    project: project,
    work_dir: work_dir,
    git_dir: git_dir,
    server: server
  } do
    original_user = Env.local_user_id()
    machine_a = Ecto.UUID.generate()
    machine_b = Ecto.UUID.generate()

    on_exit(fn -> Application.put_env(:cadence_daemon, :local_user_id, original_user) end)
    Application.put_env(:cadence_daemon, :local_user_id, machine_a)

    queue = start_queue(project, work_dir, git_dir)
    {:ok, parent} = commit(queue, work_dir, "parent")
    {:ok, child} = CommitQueue.spawn(queue, "child")

    Enum.each([parent, child], fn node ->
      assert eventually(fn -> pending?(project.id, node.id) end)
    end)

    configure_sync()
    assert :ok = Sync.sync(project.id)

    assert TestSyncServer.preferences(server, project.id)["session_pointer"] == child.id

    Application.put_env(:cadence_daemon, :local_user_id, machine_b)
    assert Session.ensure_membership!(project.id).preferences_updated_at == nil

    assert :ok = Sync.sync(project.id)

    machine_b_state = membership(project.id)
    assert machine_b_state.session_pointer == child.id
    assert machine_b_state.active_heads == [parent.id]

    Application.put_env(:cadence_daemon, :sync_enabled, false)
    assert {:ok, _membership} = Session.switch(project.id, parent.id)
    Application.put_env(:cadence_daemon, :sync_enabled, true)
    assert :ok = Sync.sync(project.id)

    Application.put_env(:cadence_daemon, :local_user_id, machine_a)
    assert :ok = Sync.sync(project.id)
    assert membership(project.id).session_pointer == parent.id
  end

  test "sync converges with the notification channel disabled", %{
    project: project,
    work_dir: work_dir,
    git_dir: git_dir,
    server: server
  } do
    queue = start_queue(project, work_dir, git_dir)
    {:ok, node} = commit(queue, work_dir, "offline socket")
    assert eventually(fn -> pending?(project.id, node.id) end)

    configure_sync()
    Application.put_env(:cadence_daemon, :sync_channel_enabled, false)

    assert :ignore = SyncSocket.start_link([])
    assert :ok = Sync.sync(project.id)

    assert SyncLedger.pending(project.id) == []
    assert Enum.any?(TestSyncServer.nodes(server), &(&1["id"] == node.id))
  end

  test "a local switch wakes the worker and pushes preferences", %{
    project: project,
    work_dir: work_dir,
    git_dir: git_dir,
    server: server
  } do
    queue = start_queue(project, work_dir, git_dir)
    {:ok, first} = commit(queue, work_dir, "first")
    {:ok, _second} = commit(queue, work_dir, "second")

    configure_sync()
    assert :ok = Sync.ensure_project(project.id)

    assert {:ok, _membership} = Session.switch(project.id, first.id)

    assert eventually(fn ->
             TestSyncServer.preferences(server, project.id)["session_pointer"] == first.id and
               SyncLedger.cursor(project.id) != nil
           end)
  end

  test "push_pending isolates a failed node and retries the rest", %{
    project: project,
    work_dir: work_dir,
    git_dir: git_dir,
    server: server
  } do
    queue = start_queue(project, work_dir, git_dir)
    {:ok, root} = commit(queue, work_dir, "root")
    {:ok, child} = commit(queue, work_dir, "child")
    assert {:ok, _membership} = Session.switch(project.id, root.id)
    {:ok, sibling} = CommitQueue.spawn(queue, "sibling")

    Enum.each([root, child, sibling], fn node ->
      assert eventually(fn -> pending?(project.id, node.id) end)
    end)

    configure_sync()
    assert :ok = Sync.ensure_project(project.id)

    TestSyncServer.fail_next_node(server, child.id, 422, %{"error" => "invalid node"})

    assert :ok = Sync.push_pending(project.id)

    assert pending_ids(project.id) == [child.id]
    assert Repo.get!(SyncPending, child.id).attempts == 1
    assert Repo.get!(SyncPending, child.id).last_error =~ "invalid node"
    refute Repo.get(SyncPending, root.id)
    refute Repo.get(SyncPending, sibling.id)

    assert Enum.sort(Enum.map(TestSyncServer.nodes(server), & &1["id"])) ==
             Enum.sort([root.id, sibling.id])
  end

  test "a failed parent leaves descendants pending until it is retried", %{
    project: project,
    work_dir: work_dir,
    git_dir: git_dir,
    server: server
  } do
    queue = start_queue(project, work_dir, git_dir)
    {:ok, root} = commit(queue, work_dir, "root")
    {:ok, parent} = commit(queue, work_dir, "parent")
    {:ok, child} = commit(queue, work_dir, "child")
    assert {:ok, _membership} = Session.switch(project.id, root.id)
    {:ok, sibling} = CommitQueue.spawn(queue, "sibling")

    Enum.each([root, parent, child, sibling], fn node ->
      assert eventually(fn -> pending?(project.id, node.id) end)
    end)

    configure_sync()
    assert :ok = Sync.ensure_project(project.id)

    TestSyncServer.fail_next_node(server, parent.id)

    assert :ok = Sync.push_pending(project.id)

    assert pending_ids(project.id) == [parent.id, child.id]
    assert Repo.get!(SyncPending, parent.id).attempts == 1
    child_pending = Repo.get!(SyncPending, child.id)
    assert child_pending.attempts == 0
    assert child_pending.last_error == nil

    assert Enum.sort(Enum.map(TestSyncServer.nodes(server), & &1["id"])) ==
             Enum.sort([root.id, sibling.id])

    past = DateTime.add(DateTime.utc_now(), -1, :second)
    assert {:ok, _pending} = SyncLedger.mark_failed(parent.id, :retry, past)

    assert :ok = Sync.push_pending(project.id)
    assert pending_ids(project.id) == []

    assert Enum.sort(Enum.map(TestSyncServer.nodes(server), & &1["id"])) ==
             Enum.sort([root.id, parent.id, child.id, sibling.id])
  end

  test "transient push failure marks the whole batch with backoff", %{
    project: project,
    work_dir: work_dir,
    git_dir: git_dir,
    server: server
  } do
    queue = start_queue(project, work_dir, git_dir)
    {:ok, first} = commit(queue, work_dir, "first")
    {:ok, second} = commit(queue, work_dir, "second")

    Enum.each([first, second], fn node ->
      assert eventually(fn -> pending?(project.id, node.id) end)
    end)

    configure_sync()
    assert :ok = Sync.ensure_project(project.id)

    TestSyncServer.fail_next(server, 500)

    assert {:error, {:http, 500, %{"error" => "forced failure"}}} =
             Sync.push_pending(project.id)

    assert pending_ids(project.id) == [first.id, second.id]
    assert SyncLedger.due_pending(project.id) == []
    assert Repo.get!(SyncPending, first.id).attempts == 1
    assert Repo.get!(SyncPending, second.id).attempts == 1
  end

  test "an out-of-batch failed_local_id falls back to whole-batch failure", %{
    project: project,
    work_dir: work_dir,
    git_dir: git_dir,
    server: server
  } do
    queue = start_queue(project, work_dir, git_dir)
    {:ok, first} = commit(queue, work_dir, "first")
    {:ok, second} = commit(queue, work_dir, "second")

    Enum.each([first, second], fn node ->
      assert eventually(fn -> pending?(project.id, node.id) end)
    end)

    configure_sync()
    assert :ok = Sync.ensure_project(project.id)

    TestSyncServer.fail_next(server, 422, %{
      "error" => "node failed",
      "failed_local_id" => Ecto.UUID.generate()
    })

    assert {:error, {:http, 422, _body}} = Sync.push_pending(project.id)

    assert pending_ids(project.id) == [first.id, second.id]
    assert Repo.get!(SyncPending, first.id).attempts == 1
    assert Repo.get!(SyncPending, second.id).attempts == 1
  end

  test "offline sync leaves pending nodes untouched", %{
    project: project,
    work_dir: work_dir,
    git_dir: git_dir
  } do
    queue = start_queue(project, work_dir, git_dir)
    {:ok, node} = commit(queue, work_dir, "first")
    assert eventually(fn -> pending?(project.id, node.id) end)

    assert {:error, :not_configured} = Sync.sync(project.id)
    assert Enum.any?(SyncLedger.pending(project.id), &(&1.id == node.id))
  end

  test "SyncWorker wakes and flushes a project in a task", %{
    project: project,
    work_dir: work_dir,
    git_dir: git_dir,
    server: server
  } do
    queue = start_queue(project, work_dir, git_dir)
    {:ok, node} = commit(queue, work_dir, "worker")
    assert eventually(fn -> pending?(project.id, node.id) end)

    configure_sync()
    SyncWorker.wake(project.id)

    assert eventually(fn -> SyncLedger.pending(project.id) == [] end)
    assert eventually(fn -> SyncLedger.cursor(project.id) != nil end)
    assert Enum.any?(TestSyncServer.nodes(server), &(&1["id"] == node.id))
  end

  defp wait_for_sync_idle(timeout \\ 3_000) do
    Process.sleep(20)
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_sync_idle(deadline)
  end

  defp do_wait_for_sync_idle(deadline) do
    cond do
      not sync_busy?() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :ok

      true ->
        Process.sleep(20)
        do_wait_for_sync_idle(deadline)
    end
  end

  defp sync_busy? do
    in_flight =
      try do
        :sys.get_state(SyncWorker).in_flight
      catch
        _kind, _reason -> %{}
      end

    children =
      try do
        Task.Supervisor.children(Cadence.Daemon.SyncTasks)
      catch
        _kind, _reason -> []
      end

    in_flight != %{} or children != []
  end

  defp membership(project_id) do
    Repo.get_by!(Membership, user_id: Env.local_user_id(), project_id: project_id)
  end

  defp configure_sync do
    Application.put_env(:cadence_daemon, :server_url, "https://cadence.test")
    Application.put_env(:cadence_daemon, :auth_token, @token)
    Application.put_env(:cadence_daemon, :sync_enabled, true)
    Application.put_env(:cadence_daemon, :sync_req_options, plug: {Req.Test, __MODULE__})
  end

  defp clear_sync_config do
    Enum.each(
      [
        :server_url,
        :auth_token,
        :sync_enabled,
        :sync_req_options,
        :sync_request_timeout_ms,
        :sync_channel_enabled
      ],
      &Application.delete_env(:cadence_daemon, &1)
    )
  end

  defp start_queue(project, work_dir, git_dir) do
    start_supervised!(
      {CommitQueue, [project_id: project.id, work_dir: work_dir, git_dir: git_dir]}
    )
  end

  defp commit(queue, work_dir, message) do
    File.write!(Path.join(work_dir, "a.txt"), "#{message}\n")
    CommitQueue.commit(queue, message)
  end

  defp pending_ids(project_id) do
    project_id |> SyncLedger.pending() |> Enum.map(& &1.id)
  end

  defp pending?(project_id, node_id) do
    Enum.any?(SyncLedger.pending(project_id), &(&1.id == node_id))
  end

  defp remote_node(project_id) do
    root = Path.join(System.tmp_dir!(), "cadence_remote_#{System.unique_integer([:positive])}")
    work = Path.join(root, "work")
    File.mkdir_p!(work)
    File.write!(Path.join(work, "README.md"), "# Remote\n")
    on_exit(fn -> File.rm_rf(root) end)

    git = GitStore.init(Path.join(root, "git"), bare: true)
    tree = GitStore.build_tree(git, work)
    commit_sha = GitStore.write_commit(git, tree, [], @author, "remote")
    {:ok, objects} = GitStore.objects_from(git, commit_sha)

    node = %Node{
      id: Ecto.UUID.generate(),
      project_id: project_id,
      git_commit_sha: commit_sha,
      parents: [],
      flags: [:"in-progress"],
      pinned: false,
      message: "remote",
      session_metadata: %{},
      created_by: @server_user,
      created_at: DateTime.utc_now(),
      docs_state: :pending
    }

    {NodeCodec.encode_node(node, objects), commit_sha, "# Remote\n"}
  end

  defp insert_project do
    %{
      name: "p",
      slug: "sync-#{System.unique_integer([:positive])}",
      owner_id: Env.local_user_id()
    }
    |> Project.changeset()
    |> Repo.insert!()
  end

  defp insert_location(project_id, work_dir, git_dir) do
    %ProjectLocation{}
    |> ProjectLocation.changeset(%{
      project_id: project_id,
      work_dir: work_dir,
      git_dir: git_dir,
      created_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp insert_node(project_id, id, sha, parents) do
    %{
      id: id,
      project_id: project_id,
      git_commit_sha: sha,
      parents: parents,
      flags: [:"in-progress"],
      message: "local",
      created_by: Env.local_user_id(),
      created_at: DateTime.utc_now(),
      docs_state: :pending
    }
    |> Node.changeset()
    |> Repo.insert!()
  end

  defp eventually(fun, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    try_until(fun, deadline)
  end

  defp try_until(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition not met within timeout")
      else
        Process.sleep(20)
        try_until(fun, deadline)
      end
    end
  end
end
