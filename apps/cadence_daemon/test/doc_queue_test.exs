defmodule Cadence.Daemon.DocQueueTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Cadence.Daemon.{
    CommitQueue,
    DocDiff,
    DocQueue,
    ProjectLocation,
    ProjectRegistry,
    Repo,
    SyncLedger
  }

  alias Cadence.Shared.{GitStore, Node, Project}

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
    root = Path.join(System.tmp_dir!(), "cadence_docs_#{System.unique_integer([:positive])}")
    work_dir = Path.join(root, "work")
    git_dir = Path.join(root, "git")
    File.mkdir_p!(work_dir)

    owner_id = Ecto.UUID.generate()

    {:ok, project} =
      %{name: "p", slug: "p-#{System.unique_integer([:positive])}", owner_id: owner_id}
      |> Project.changeset()
      |> Repo.insert()

    %ProjectLocation{}
    |> ProjectLocation.changeset(%{
      project_id: project.id,
      work_dir: work_dir,
      git_dir: git_dir,
      created_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    Application.put_env(:cadence_daemon, :docs_llm, Cadence.Daemon.TestDocsLLM)
    Application.put_env(:cadence_daemon, :docs_retry_backoff_ms, 10)
    # Keep the shared `:docs` window out of other tests' way.
    Application.put_env(:cadence_daemon, :docs_rate_limit, 1_000)
    Application.put_env(:cadence_daemon, :docs_rate_scale, 60_000)

    on_exit(fn ->
      drain_doc_queue()
      File.rm_rf!(root)

      for key <- [
            :docs_llm,
            :docs_retry_backoff_ms,
            :docs_rate_limit,
            :docs_rate_scale,
            :docs_timeout_ms,
            :docs_retry_attempts,
            :docs_enabled,
            :docs_context_bytes,
            :docs_max_files,
            :test_docs_llm_result
          ] do
        Application.delete_env(:cadence_daemon, key)
      end
    end)

    %{root: root, work_dir: work_dir, git_dir: git_dir, project: project}
  end

  test "generates docs as a follow-up commit under the node", ctx do
    queue = start_queue(ctx)
    write_triggering_change(ctx)

    {:ok, node} = CommitQueue.commit(queue, "code change")

    assert node.docs_state == :pending
    assert node.session_metadata["docs"]["state"] == "pending"
    assert node.session_metadata["docs"]["code_commit_sha"] == node.git_commit_sha
    assert node.session_metadata["code_commit_sha"] == node.git_commit_sha

    assert eventually(fn -> Repo.get!(Node, node.id).docs_state == :current end)

    loaded = Repo.get!(Node, node.id)

    assert loaded.git_commit_sha != node.git_commit_sha
    assert loaded.parents == node.parents
    assert loaded.session_metadata["docs"]["docs_commit_sha"] == loaded.git_commit_sha
    assert loaded.session_metadata["docs"]["code_commit_sha"] == node.git_commit_sha
    assert loaded.session_metadata["docs"]["model"] == "test-docs-model"
    assert loaded.session_metadata["docs"]["provider"] == "test"
    assert loaded.session_metadata["docs"]["prompt_version"] == "docs-v1"
    assert loaded.session_metadata["docs"]["paths"] == ["README.md"]

    git = GitStore.init(ctx.git_dir, bare: true)
    docs_commit = GitStore.read_commit(git, loaded.git_commit_sha)
    assert docs_commit.parent == [node.git_commit_sha]

    assert {:ok, readme} = GitStore.read_path(git, loaded.git_commit_sha, "README.md")
    assert readme =~ "## Overview"

    assert File.read!(Path.join(ctx.work_dir, "README.md")) =~ "## Overview"

    assert eventually(fn ->
             SyncLedger.pushable(ctx.project.id, nil, 10) |> Enum.any?(&(&1.id == node.id))
           end)

    assert {:ok, diff} = DocDiff.build(ctx.project.id, node.id)
    assert Enum.map(diff.files, & &1.path) == ["README.md"]
    assert diff.code_commit_sha == node.git_commit_sha
    assert diff.docs_commit_sha == loaded.git_commit_sha
  end

  test "marks the node current when the docs generation is empty", ctx do
    # Seed a project whose index already satisfies the required sections, then
    # make a triggering code change and return no operations.
    Application.put_env(:cadence_daemon, :docs_enabled, false)

    queue = start_queue(ctx)
    write_triggering_change(ctx)
    File.write!(Path.join(ctx.work_dir, "README.md"), "# Project\n\n## Overview\n\nexisting\n")

    {:ok, _seed} = CommitQueue.commit(queue, "seed")
    Application.delete_env(:cadence_daemon, :docs_enabled)

    Application.put_env(:cadence_daemon, :test_docs_llm_result, {:ok, "DOCS_BEGIN\nDOCS_END\n"})
    File.write!(Path.join(ctx.work_dir, "lib/demo.ex"), @code <> "\n# touched\n")

    {:ok, node} = CommitQueue.commit(queue, "code change")

    assert eventually(fn -> Repo.get!(Node, node.id).docs_state == :current end)

    loaded = Repo.get!(Node, node.id)
    assert loaded.git_commit_sha == node.git_commit_sha
    refute Map.has_key?(loaded.session_metadata["docs"], "docs_commit_sha")
    assert loaded.session_metadata["docs"]["empty"] == true
    assert loaded.session_metadata["docs"]["paths"] == []
    assert DocDiff.build(ctx.project.id, node.id) == {:error, :no_docs_commit}
  end

  test "retries a malformed response and then defers the docs", ctx do
    Application.put_env(:cadence_daemon, :test_docs_llm_result, {:ok, "not a docs response"})

    queue = start_queue(ctx)
    write_triggering_change(ctx)

    {:ok, node} = CommitQueue.commit(queue, "code change")

    assert eventually(fn ->
             Repo.get!(Node, node.id).session_metadata["docs"]["state"] == "deferred"
           end)

    loaded = Repo.get!(Node, node.id)

    # Code is never blocked by docs: still pending, still at C1, now pushable.
    assert loaded.docs_state == :pending
    assert loaded.git_commit_sha == node.git_commit_sha
    assert loaded.session_metadata["docs"]["error"] =~ "missing_begin"

    assert eventually(fn ->
             SyncLedger.pushable(ctx.project.id, nil, 10) |> Enum.any?(&(&1.id == node.id))
           end)
  end

  test "a timed-out call is retried and then deferred", ctx do
    Application.put_env(:cadence_daemon, :test_docs_llm_result, {:sleep, 200})
    Application.put_env(:cadence_daemon, :docs_timeout_ms, 20)
    Application.put_env(:cadence_daemon, :docs_retry_attempts, 1)

    queue = start_queue(ctx)
    write_triggering_change(ctx)

    {:ok, node} = CommitQueue.commit(queue, "code change")

    assert eventually(fn ->
             Repo.get!(Node, node.id).session_metadata["docs"]["state"] == "deferred"
           end)

    loaded = Repo.get!(Node, node.id)
    assert loaded.session_metadata["docs"]["error"] =~ "timeout"
    assert loaded.git_commit_sha == node.git_commit_sha
  end

  test "a rate-limited call is deferred without calling the model", ctx do
    Application.put_env(:cadence_daemon, :docs_rate_limit, 0)

    queue = start_queue(ctx)
    write_triggering_change(ctx)

    {:ok, node} = CommitQueue.commit(queue, "code change")

    assert eventually(fn ->
             Repo.get!(Node, node.id).session_metadata["docs"]["state"] == "deferred"
           end)

    loaded = Repo.get!(Node, node.id)
    assert loaded.session_metadata["docs"]["error"] =~ "rate_limited"
  end

  test "an unconfigured LLM defers the docs instead of failing the commit", ctx do
    Application.delete_env(:cadence_daemon, :docs_llm)
    previous = Application.get_env(:cadence_shared, Cadence.Shared.LLM)

    Application.put_env(:cadence_shared, Cadence.Shared.LLM,
      provider: "deepseek",
      model: "test",
      api_key: nil
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:cadence_shared, Cadence.Shared.LLM, previous),
        else: Application.delete_env(:cadence_shared, Cadence.Shared.LLM)
    end)

    queue = start_queue(ctx)
    write_triggering_change(ctx)

    {:ok, node} = CommitQueue.commit(queue, "code change")

    assert eventually(fn ->
             Repo.get!(Node, node.id).session_metadata["docs"]["state"] == "deferred"
           end)

    loaded = Repo.get!(Node, node.id)
    assert loaded.session_metadata["docs"]["error"] =~ "not_configured"

    assert eventually(fn ->
             SyncLedger.pushable(ctx.project.id, nil, 10) |> Enum.any?(&(&1.id == node.id))
           end)
  end

  test "rehydrate resumes a job that was pending at boot", ctx do
    Application.put_env(:cadence_daemon, :docs_enabled, false)

    queue = start_queue(ctx)
    write_triggering_change(ctx)

    {:ok, node} = CommitQueue.commit(queue, "code change")
    assert node.docs_state == :skipped

    Application.delete_env(:cadence_daemon, :docs_enabled)

    docs = %{
      "state" => "pending",
      "code_commit_sha" => node.git_commit_sha,
      "reasons" => ["schema_changed"]
    }

    node
    |> Node.changeset(%{
      docs_state: :pending,
      session_metadata: %{"docs" => docs, "code_commit_sha" => node.git_commit_sha}
    })
    |> Repo.update!()

    assert :ok = DocQueue.rehydrate()
    assert eventually(fn -> Repo.get!(Node, node.id).docs_state == :current end)
  end

  test "retry_pending re-arms a deferred job", ctx do
    Application.put_env(:cadence_daemon, :test_docs_llm_result, {:ok, "bad response"})
    Application.put_env(:cadence_daemon, :docs_retry_attempts, 1)

    queue = start_queue(ctx)
    write_triggering_change(ctx)

    {:ok, node} = CommitQueue.commit(queue, "code change")

    assert eventually(fn ->
             Repo.get!(Node, node.id).session_metadata["docs"]["state"] == "deferred"
           end)

    Application.delete_env(:cadence_daemon, :test_docs_llm_result)

    assert :ok = DocQueue.retry_pending(ctx.project.id)
    assert eventually(fn -> Repo.get!(Node, node.id).docs_state == :current end)
  end

  test "force sync generates docs for a code-only node", ctx do
    Application.put_env(:cadence_daemon, :docs_enabled, false)

    queue = start_queue(ctx)
    write_triggering_change(ctx)
    File.write!(Path.join(ctx.work_dir, "README.md"), "# Project\n\n## Overview\n")

    {:ok, node} = CommitQueue.commit(queue, "seed")
    assert node.docs_state == :skipped
    refute Map.has_key?(node.session_metadata, "docs")

    Application.delete_env(:cadence_daemon, :docs_enabled)

    Application.put_env(
      :cadence_daemon,
      :test_docs_llm_result,
      {:ok,
       """
       DOCS_BEGIN
       FILE MODIFY README.md
       <<<
       # Project

       ## Overview

       generated
       >>>
       DOCS_END
       """}
    )

    DocQueue.enqueue(ctx.project.id, node.id, force: true)
    assert eventually(fn -> Repo.get!(Node, node.id).docs_state == :current end)

    loaded = Repo.get!(Node, node.id)
    assert loaded.git_commit_sha != node.git_commit_sha
    assert loaded.session_metadata["docs"]["docs_commit_sha"] == loaded.git_commit_sha

    # A second forced run that produces no operations must keep the existing C2
    # instead of rewinding the node to C1.
    docs_sha = loaded.git_commit_sha
    generated_at = loaded.session_metadata["docs"]["generated_at"]

    Application.put_env(:cadence_daemon, :test_docs_llm_result, {:ok, "DOCS_BEGIN\nDOCS_END\n"})
    DocQueue.enqueue(ctx.project.id, node.id, force: true)

    assert eventually(fn ->
             Repo.get!(Node, node.id).session_metadata["docs"]["generated_at"] != generated_at
           end)

    reloaded = Repo.get!(Node, node.id)
    assert reloaded.git_commit_sha == docs_sha
    assert reloaded.session_metadata["docs"]["docs_commit_sha"] == docs_sha
    refute reloaded.session_metadata["docs"]["empty"]
  end

  test "a pushed node without docs metadata is not regenerated by force sync", ctx do
    Application.put_env(:cadence_daemon, :docs_enabled, false)

    queue = start_queue(ctx)
    write_triggering_change(ctx)

    {:ok, node} = CommitQueue.commit(queue, "code change")
    assert node.docs_state == :skipped
    refute Map.has_key?(node.session_metadata, "docs")

    assert :ok = SyncLedger.mark_pushed([node.id])
    assert Repo.get!(Node, node.id).session_metadata["docs_pushed_sha"] == node.git_commit_sha

    ref = make_ref()

    Application.put_env(
      :cadence_daemon,
      :test_docs_llm_result,
      {:block, self(), ref, "DOCS_BEGIN\nDOCS_END\n"}
    )

    DocQueue.enqueue(ctx.project.id, node.id, force: true)
    refute_receive {:docs_llm_started, ^ref, _pid}, 200

    reloaded = Repo.get!(Node, node.id)
    assert reloaded.git_commit_sha == node.git_commit_sha
    refute Map.has_key?(reloaded.session_metadata, "docs")
  end

  test "a pushed deferred node is never re-generated", ctx do
    Application.put_env(:cadence_daemon, :test_docs_llm_result, {:ok, "bad response"})
    Application.put_env(:cadence_daemon, :docs_retry_attempts, 1)

    queue = start_queue(ctx)
    write_triggering_change(ctx)

    {:ok, node} = CommitQueue.commit(queue, "code change")

    assert eventually(fn ->
             Repo.get!(Node, node.id).session_metadata["docs"]["state"] == "deferred"
           end)

    assert :ok = SyncLedger.mark_pushed([node.id])
    loaded = Repo.get!(Node, node.id)
    assert loaded.session_metadata["docs_pushed_sha"] == node.git_commit_sha

    Application.delete_env(:cadence_daemon, :test_docs_llm_result)
    assert :ok = DocQueue.retry_pending(ctx.project.id)
    assert :sys.get_state(DocQueue).entries == %{}
    Process.sleep(100)

    loaded = Repo.get!(Node, node.id)
    assert loaded.git_commit_sha == node.git_commit_sha
    assert loaded.session_metadata["docs"]["state"] == "deferred"
  end

  test "disabling docs releases a queued node as skipped", ctx do
    Application.put_env(:cadence_daemon, :docs_enabled, false)

    queue = start_queue(ctx)
    write_triggering_change(ctx)

    {:ok, node} = CommitQueue.commit(queue, "code change")
    assert node.docs_state == :skipped

    docs = %{"state" => "pending", "code_commit_sha" => node.git_commit_sha}

    node
    |> Node.changeset(%{
      docs_state: :pending,
      session_metadata: %{"docs" => docs, "code_commit_sha" => node.git_commit_sha}
    })
    |> Repo.update!()

    assert :ok = DocQueue.rehydrate()

    assert eventually(fn ->
             Repo.get!(Node, node.id).session_metadata["docs"]["state"] == "skipped"
           end)

    assert Repo.get!(Node, node.id).docs_state == :skipped
  end

  test "an oversized context is deferred without retries", ctx do
    Application.put_env(:cadence_daemon, :docs_context_bytes, 10)

    queue = start_queue(ctx)
    write_triggering_change(ctx)

    {:ok, node} = CommitQueue.commit(queue, "code change")

    assert eventually(fn ->
             Repo.get!(Node, node.id).session_metadata["docs"]["state"] == "deferred"
           end)

    loaded = Repo.get!(Node, node.id)
    assert loaded.session_metadata["docs"]["error"] =~ "context_too_large"
    assert loaded.git_commit_sha == node.git_commit_sha
  end

  test "leaves a diverged working-tree file untouched and records it", ctx do
    ref = make_ref()

    Application.put_env(
      :cadence_daemon,
      :test_docs_llm_result,
      {:block, self(), ref,
       """
       DOCS_BEGIN
       FILE MODIFY docs/guide.md
       <<<
       # Guide

       ## Overview

       generated
       >>>
       DOCS_END
       """}
    )

    File.write!(Path.join(ctx.work_dir, ".caddocs.yaml"), @schema)
    File.write!(Path.join(ctx.work_dir, "README.md"), "# Project\n\n## Overview\n")
    File.mkdir_p!(Path.join(ctx.work_dir, "docs"))
    File.write!(Path.join(ctx.work_dir, "docs/guide.md"), "old content\n")
    File.mkdir_p!(Path.join(ctx.work_dir, "lib"))
    File.write!(Path.join(ctx.work_dir, "lib/demo.ex"), @code)

    queue = start_queue(ctx)
    {:ok, node} = CommitQueue.commit(queue, "code change")

    # Hold the model until the user has edited the doc, then release it.
    assert_receive {:docs_llm_started, ^ref, task_pid}, 2_000
    File.write!(Path.join(ctx.work_dir, "docs/guide.md"), "user edit\n")
    send(task_pid, {:docs_llm_continue, ref})

    assert eventually(fn -> Repo.get!(Node, node.id).docs_state == :current end)

    loaded = Repo.get!(Node, node.id)
    assert File.read!(Path.join(ctx.work_dir, "docs/guide.md")) == "user edit\n"
    assert loaded.session_metadata["docs"]["workdir_skipped"] == ["docs/guide.md"]

    git = GitStore.init(ctx.git_dir, bare: true)

    assert {:ok, committed} =
             GitStore.read_path(git, loaded.git_commit_sha, "docs/guide.md")

    assert committed =~ "generated"
  end

  test "never writes through a symlinked docs directory", ctx do
    outside = Path.join(ctx.root, "outside")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "guide.md"), "outside\n")
    File.ln_s!(outside, Path.join(ctx.work_dir, "docs"))

    Application.put_env(
      :cadence_daemon,
      :test_docs_llm_result,
      {:ok,
       """
       DOCS_BEGIN
       FILE CREATE docs/guide.md
       <<<
       # Guide

       ## Overview

       generated
       >>>
       DOCS_END
       """}
    )

    File.write!(Path.join(ctx.work_dir, ".caddocs.yaml"), @schema)
    File.write!(Path.join(ctx.work_dir, "README.md"), "# Project\n\n## Overview\n")
    File.mkdir_p!(Path.join(ctx.work_dir, "lib"))
    File.write!(Path.join(ctx.work_dir, "lib/demo.ex"), @code)

    queue = start_queue(ctx)
    {:ok, node} = CommitQueue.commit(queue, "code change")

    assert eventually(fn -> Repo.get!(Node, node.id).docs_state == :current end)

    loaded = Repo.get!(Node, node.id)
    assert File.read!(Path.join(outside, "guide.md")) == "outside\n"
    assert loaded.session_metadata["docs"]["workdir_skipped"] == ["docs/guide.md"]

    git = GitStore.init(ctx.git_dir, bare: true)
    assert {:ok, committed} = GitStore.read_path(git, loaded.git_commit_sha, "docs/guide.md")
    assert committed =~ "generated"
  end

  test "a doc write does not create a second node", ctx do
    # Files exist before the watcher subscribes, so only the doc write can
    # generate an event. A late event is absorbed by the unchanged-tree guard.
    write_triggering_change(ctx)

    {:ok, supervisor} =
      ProjectRegistry.start_project(
        project_id: ctx.project.id,
        work_dir: ctx.work_dir,
        git_dir: ctx.git_dir,
        backend: :fs_poll,
        interval: 50,
        debounce_ms: 50
      )

    on_exit(fn ->
      DynamicSupervisor.terminate_child(ProjectRegistry, supervisor)
    end)

    queue = ProjectRegistry.lookup_queue(ctx.project.id)
    watcher = {:via, Registry, {Cadence.Daemon.Queues, {:watcher, ctx.project.id}}}

    Process.sleep(300)

    {:ok, node} = CommitQueue.commit(queue, "code change")

    assert eventually(fn -> Repo.get!(Node, node.id).docs_state == :current end)

    # Simulate the poller reporting the doc write after `resume`: the tree
    # equals the node's docs commit, so the watcher commit is a no-op.
    send(GenServer.whereis(watcher), {:file_event, self(), {"README.md", [:modified]}})
    Process.sleep(200)

    count =
      Repo.aggregate(
        where(Node, [n], n.project_id == ^ctx.project.id),
        :count
      )

    assert count == 1
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

  defp start_queue(ctx) do
    start_supervised!(
      {CommitQueue, [project_id: ctx.project.id, work_dir: ctx.work_dir, git_dir: ctx.git_dir]}
    )
  end

  defp write_triggering_change(ctx) do
    File.write!(Path.join(ctx.work_dir, ".caddocs.yaml"), @schema)
    File.mkdir_p!(Path.join(ctx.work_dir, "lib"))
    File.write!(Path.join(ctx.work_dir, "lib/demo.ex"), @code)
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
