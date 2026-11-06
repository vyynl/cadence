defmodule Cadence.Daemon.DocReconnectTest do
  @moduledoc """
  End-to-end reconnect coverage for deferred documentation (spec §9.5, P4-T1).

  A commit made while the daemon is offline leaves its doc job deferred and its
  node unpushed. On reconnect the deferred job runs *before* the push, so the
  server receives one node pointing at the follow-up docs commit (`C2`) instead
  of the code-only commit (`C1`). A job that fails again is still pushed
  code-only — docs never block sync (D6).
  """

  use ExUnit.Case, async: false

  alias Cadence.Daemon.{
    CommitQueue,
    DocQueue,
    Env,
    ProjectLocation,
    Repo,
    Sync,
    SyncLedger,
    SyncWorker
  }

  alias Cadence.Daemon.TestSyncServer
  alias Cadence.Shared.{GitStore, Node, Project}

  @server_user "11111111-1111-4111-8111-111111111111"
  @token "cad-test-token"

  @schema """
  index_file: README.md
  docs_dir: docs
  sections:
    - name: Overview
      required: true
      generated_from: "lib/**/*.ex"
  """

  @code """
  defmodule Demo do
    def hello, do: :world
  end
  """

  setup do
    root =
      Path.join(System.tmp_dir!(), "cadence_doc_reconnect_#{System.unique_integer([:positive])}")

    work_dir = Path.join(root, "work")
    git_dir = Path.join(root, "git")
    File.mkdir_p!(work_dir)

    project = insert_project()
    insert_location(project.id, work_dir, git_dir)

    {:ok, server} = TestSyncServer.start(@server_user)
    TestSyncServer.stub(__MODULE__, server)
    Req.Test.set_req_test_to_shared()
    previous_llm = Application.get_env(:cadence_shared, Cadence.Shared.LLM)

    # Keep the shared `:docs` limiter and retry backoff out of other tests' way.
    Application.put_env(:cadence_daemon, :docs_retry_backoff_ms, 10)
    Application.put_env(:cadence_daemon, :docs_rate_limit, 1_000)
    Application.put_env(:cadence_daemon, :docs_rate_scale, 60_000)

    on_exit(fn ->
      Application.put_env(:cadence_daemon, :sync_enabled, false)
      drain_doc_queue()
      wait_for_sync_idle()
      Req.Test.set_req_test_to_private()
      clear_sync_config()

      for key <- [
            :docs_llm,
            :docs_retry_backoff_ms,
            :docs_rate_limit,
            :docs_rate_scale,
            :docs_retry_attempts,
            :test_docs_llm_result
          ] do
        Application.delete_env(:cadence_daemon, key)
      end

      if previous_llm,
        do: Application.put_env(:cadence_shared, Cadence.Shared.LLM, previous_llm),
        else: Application.delete_env(:cadence_shared, Cadence.Shared.LLM)

      File.rm_rf(root)
    end)

    %{
      project: project,
      work_dir: work_dir,
      git_dir: git_dir,
      server: server
    }
  end

  test "reconnect retries deferred docs before pushing one node at C2", ctx do
    node = commit_offline(ctx)

    # Reconnect: the docs client and the server are available again.
    Application.put_env(:cadence_daemon, :docs_llm, Cadence.Daemon.TestDocsLLM)
    configure_sync()

    SyncWorker.wake(ctx.project.id)

    assert eventually(fn -> docs_state(node.id) == "current" end)

    # The push may have already been triggered by the queue completion; wake
    # again if the worker was in flight at that moment (the cast is dropped).
    wait_for_sync_idle()
    _ = :sys.get_state(SyncLedger)
    SyncWorker.wake(ctx.project.id)

    assert eventually(fn -> length(TestSyncServer.nodes(ctx.server)) == 1 end)
    wait_for_sync_idle()

    loaded = Repo.get!(Node, node.id)
    [wire] = TestSyncServer.nodes(ctx.server)

    # One node, at the docs commit — the code-only C1 was never pushed.
    assert wire["id"] == node.id
    assert wire["git_commit_sha"] == loaded.git_commit_sha
    assert wire["docs_state"] == "current"
    assert wire["session_metadata"]["docs"]["state"] == "current"
    assert wire["session_metadata"]["docs"]["docs_commit_sha"] == loaded.git_commit_sha
    refute wire["git_commit_sha"] == node.git_commit_sha

    assert loaded.docs_state == :current
    assert loaded.git_commit_sha != node.git_commit_sha
    assert loaded.session_metadata["docs"]["code_commit_sha"] == node.git_commit_sha

    git = GitStore.init(ctx.git_dir, bare: true)
    assert GitStore.read_commit(git, loaded.git_commit_sha).parent == [node.git_commit_sha]

    assert SyncLedger.pending(ctx.project.id) == []
  end

  test "a failed reconnect retry still pushes the code-only node", ctx do
    node = commit_offline(ctx)

    # The server is reachable again but the doc client is still down. The
    # background worker is disabled here so the two passes can be driven
    # directly; the retry must not hold the node out of sync forever (D6).
    configure_sync()
    Application.put_env(:cadence_daemon, :sync_enabled, false)

    assert :ok = Sync.sync(ctx.project.id, retry_docs: true)

    drain_doc_queue()
    _ = :sys.get_state(SyncLedger)

    assert docs_state(node.id) == "deferred"
    assert :ok = Sync.sync(ctx.project.id)

    assert eventually(fn -> length(TestSyncServer.nodes(ctx.server)) == 1 end)

    loaded = Repo.get!(Node, node.id)
    [wire] = TestSyncServer.nodes(ctx.server)

    # One node, still at the code commit: the docs were left deferred.
    assert wire["id"] == node.id
    assert wire["git_commit_sha"] == node.git_commit_sha
    assert wire["docs_state"] == "pending"
    assert wire["session_metadata"]["docs"]["state"] == "deferred"

    assert loaded.git_commit_sha == node.git_commit_sha
    assert loaded.session_metadata["docs_pushed_sha"] == node.git_commit_sha
    assert SyncLedger.pending(ctx.project.id) == []
  end

  ## Offline commit

  # No server and no LLM key: the commit succeeds and its doc job is deferred
  # instead of failing the commit (§9.5, D6). The node stays unpushed.
  defp commit_offline(ctx) do
    Application.delete_env(:cadence_daemon, :docs_llm)

    Application.put_env(:cadence_shared, Cadence.Shared.LLM,
      provider: "deepseek",
      model: "test",
      api_key: nil
    )

    queue =
      start_supervised!(
        {CommitQueue, [project_id: ctx.project.id, work_dir: ctx.work_dir, git_dir: ctx.git_dir]}
      )

    File.write!(Path.join(ctx.work_dir, ".caddocs.yaml"), @schema)
    File.mkdir_p!(Path.join(ctx.work_dir, "lib"))
    File.write!(Path.join(ctx.work_dir, "lib/demo.ex"), @code)

    {:ok, node} = CommitQueue.commit(queue, "code change")

    assert node.docs_state == :pending
    assert node.session_metadata["docs"]["state"] == "pending"
    assert node.session_metadata["docs"]["code_commit_sha"] == node.git_commit_sha

    assert eventually(fn -> docs_state(node.id) == "deferred" end)
    assert Enum.any?(SyncLedger.pending(ctx.project.id), &(&1.id == node.id))
    refute Repo.get!(Node, node.id).session_metadata["docs_pushed_sha"]

    node
  end

  ## Helpers

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

  defp docs_state(node_id) do
    case Repo.get(Node, node_id) do
      %Node{session_metadata: %{"docs" => %{"state" => state}}} -> state
      _ -> nil
    end
  end

  defp insert_project do
    %{
      name: "p",
      slug: "doc-reconnect-#{System.unique_integer([:positive])}",
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

  defp drain_doc_queue do
    deadline = System.monotonic_time(:millisecond) + 5_000
    do_drain(deadline)
  end

  defp do_drain(deadline) do
    state =
      try do
        :sys.get_state(DocQueue, 2_000)
      catch
        :exit, _reason -> %{}
      end

    if Map.get(state, :entries) == %{} or System.monotonic_time(:millisecond) >= deadline do
      :ok
    else
      Process.sleep(20)
      do_drain(deadline)
    end
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

  defp eventually(fun, timeout \\ 5_000) do
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
