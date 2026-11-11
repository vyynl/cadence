defmodule Cadence.Daemon.CommitQueueTest do
  use ExUnit.Case, async: false

  import Cadence.Daemon.TestHelpers, only: [eventually: 1]

  alias Cadence.Daemon.{CommitQueue, ProjectLocation, Repo, Session, SyncLedger, SyncPending}
  alias Cadence.Shared.{GitStore, Node, Project}

  @docs_schema """
  index_file: README.md
  docs_dir: docs
  sections:
    - name: Overview
      required: true
      generated_from: "lib/**/*.ex"
  """

  setup do
    root = Path.join(System.tmp_dir!(), "cadence_queue_#{System.unique_integer([:positive])}")
    work_dir = Path.join(root, "work")
    git_dir = Path.join(root, "git")
    File.mkdir_p!(work_dir)

    owner_id = Ecto.UUID.generate()

    {:ok, project} =
      %{name: "p", slug: "p-#{System.unique_integer([:positive])}", owner_id: owner_id}
      |> Project.changeset()
      |> Repo.insert()

    # MessageQueue reconstructs the diff from the project location, so register
    # one here (production does this in `Projects.register_project/1`).
    %ProjectLocation{}
    |> ProjectLocation.changeset(%{
      project_id: project.id,
      work_dir: work_dir,
      git_dir: git_dir,
      created_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    on_exit(fn -> File.rm_rf!(root) end)

    %{work_dir: work_dir, git_dir: git_dir, project: project}
  end

  test "commits the working tree and chains parents",
       %{work_dir: work_dir, git_dir: git_dir, project: project} do
    queue =
      start_supervised!(
        {CommitQueue, [project_id: project.id, work_dir: work_dir, git_dir: git_dir]}
      )

    File.write!(Path.join(work_dir, "a.txt"), "hello\n")

    {:ok, first} = CommitQueue.commit(queue, "first")
    assert first.parents == []
    assert first.message == "first"
    assert first.git_commit_sha =~ ~r/^[0-9a-f]{40}$/

    git = GitStore.init(git_dir, bare: true)
    assert GitStore.read_commit(git, first.git_commit_sha).message == "first"

    File.write!(Path.join(work_dir, "b.txt"), "world\n")

    {:ok, second} = CommitQueue.commit(queue, "second")
    assert second.parents == [first.id]
    assert GitStore.read_commit(git, second.git_commit_sha).parent == [first.git_commit_sha]
  end

  test "a commit advances the session pointer",
       %{work_dir: work_dir, git_dir: git_dir, project: project} do
    queue =
      start_supervised!(
        {CommitQueue, [project_id: project.id, work_dir: work_dir, git_dir: git_dir]}
      )

    {:ok, first} = CommitQueue.commit(queue, "first")
    assert Session.current_node(project.id).id == first.id

    {:ok, second} = CommitQueue.commit(queue, "second")
    assert Session.current_node(project.id).id == second.id
  end

  test "a commit parents from the session pointer after a switch",
       %{work_dir: work_dir, git_dir: git_dir, project: project} do
    queue =
      start_supervised!(
        {CommitQueue, [project_id: project.id, work_dir: work_dir, git_dir: git_dir]}
      )

    {:ok, first} = CommitQueue.commit(queue, "first")
    {:ok, second} = CommitQueue.commit(queue, "second")
    assert second.parents == [first.id]

    {:ok, _} = Session.switch(project.id, first.id)

    File.write!(Path.join(work_dir, "c.txt"), "branch\n")
    {:ok, third} = CommitQueue.commit(queue, "third")

    assert third.parents == [first.id]

    git = GitStore.init(git_dir, bare: true)
    assert GitStore.read_commit(git, third.git_commit_sha).parent == [first.git_commit_sha]
  end

  test "node lookup is deterministic when timestamps tie",
       %{work_dir: work_dir, git_dir: git_dir, project: project} do
    created_at = ~U[2026-10-14 12:00:00.000000Z]
    [high_id, low_id] = Enum.sort([Ecto.UUID.generate(), Ecto.UUID.generate()], :desc)
    low = insert_node(project, low_id, created_at)
    high = insert_node(project, high_id, created_at)

    queue =
      start_supervised!(
        {CommitQueue, [project_id: project.id, work_dir: work_dir, git_dir: git_dir]}
      )

    # No session pointer yet, so the first commit falls back to the latest node,
    # which must be the higher-id node when created_at ties (deterministic).
    {:ok, child} = CommitQueue.commit(queue, "child")

    assert child.parents == [high.id]
    refute child.parents == [low.id]
  end

  test "commit skips configured ignore directories",
       %{work_dir: work_dir, git_dir: git_dir, project: project} do
    Application.put_env(:cadence_daemon, :ignore, ["_build"])
    on_exit(fn -> Application.delete_env(:cadence_daemon, :ignore) end)

    File.mkdir_p!(Path.join(work_dir, "_build"))
    File.write!(Path.join(work_dir, "_build/junk.beam"), "x")
    File.write!(Path.join(work_dir, "src.txt"), "ok\n")

    queue =
      start_supervised!(
        {CommitQueue, [project_id: project.id, work_dir: work_dir, git_dir: git_dir]}
      )

    {:ok, node} = CommitQueue.commit(queue, "first")

    git = GitStore.init(git_dir, bare: true)
    tree = GitStore.read_commit(git, node.git_commit_sha).tree
    assert git |> GitStore.read_tree(tree) |> Enum.map(& &1.name) == ["src.txt"]
  end

  test "auto-generates a message via the LLM",
       %{work_dir: work_dir, git_dir: git_dir, project: project} do
    Application.put_env(:cadence_daemon, :llm, Cadence.Daemon.TestLLM)

    Application.put_env(
      :cadence_daemon,
      :test_llm_result,
      {:ok, "SUMMARY: Generated\nFLAG: functioning\nDETAIL:\n- x\n"}
    )

    on_exit(fn ->
      Application.delete_env(:cadence_daemon, :llm)
      Application.delete_env(:cadence_daemon, :test_llm_result)
    end)

    queue =
      start_supervised!(
        {CommitQueue, [project_id: project.id, work_dir: work_dir, git_dir: git_dir]}
      )

    File.write!(Path.join(work_dir, "a.txt"), "hi\n")

    {:ok, node} = CommitQueue.commit(queue)

    # The commit returns immediately with a placeholder; MessageQueue fills the
    # real message in the background (spec §5.3, §5.5).
    assert node.message == "session commit"
    assert node.session_metadata["message_pending"] == true

    assert eventually(fn ->
             loaded = Repo.get!(Node, node.id)

             loaded.message == "Generated\n\n- x" and
               loaded.flags == [:"in-progress"] and
               loaded.session_metadata == %{"model" => "test-model"}
           end)
  end

  test "falls back to a placeholder and marks pending when the LLM fails",
       %{work_dir: work_dir, git_dir: git_dir, project: project} do
    Application.put_env(:cadence_daemon, :llm, Cadence.Daemon.TestLLM)
    Application.put_env(:cadence_daemon, :test_llm_result, {:error, :boom})

    on_exit(fn ->
      Application.delete_env(:cadence_daemon, :llm)
      Application.delete_env(:cadence_daemon, :test_llm_result)
    end)

    queue =
      start_supervised!(
        {CommitQueue, [project_id: project.id, work_dir: work_dir, git_dir: git_dir]}
      )

    File.write!(Path.join(work_dir, "a.txt"), "hi\n")

    {:ok, node} = CommitQueue.commit(queue)

    assert node.message == "session commit"
    assert node.flags == [:"in-progress"]
    assert node.session_metadata["message_pending"] == true
  end

  test "a commit without a docs schema skips docs and enqueues sync",
       %{work_dir: work_dir, git_dir: git_dir, project: project} do
    queue =
      start_supervised!(
        {CommitQueue, [project_id: project.id, work_dir: work_dir, git_dir: git_dir]}
      )

    File.write!(Path.join(work_dir, "a.txt"), "hi\n")

    {:ok, node} = CommitQueue.commit(queue, "first")

    assert node.docs_state == :skipped
    refute Map.has_key?(node.session_metadata, "docs")
    assert eventually(fn -> SyncLedger.pending(project.id) != [] end)
  end

  test "a matching trigger queues a doc job and holds sync until it resolves",
       %{work_dir: work_dir, git_dir: git_dir, project: project} do
    Application.put_env(:cadence_daemon, :docs_llm, Cadence.Daemon.TestDocsLLM)
    Application.put_env(:cadence_daemon, :test_docs_llm_result, {:sleep, 150})

    on_exit(fn ->
      Application.delete_env(:cadence_daemon, :docs_llm)
      Application.delete_env(:cadence_daemon, :test_docs_llm_result)
    end)

    queue =
      start_supervised!(
        {CommitQueue, [project_id: project.id, work_dir: work_dir, git_dir: git_dir]}
      )

    File.write!(Path.join(work_dir, ".caddocs.yaml"), @docs_schema)
    File.mkdir_p!(Path.join(work_dir, "lib"))
    File.write!(Path.join(work_dir, "lib/demo.ex"), "defmodule Demo do\nend\n")

    {:ok, node} = CommitQueue.commit(queue, "code")

    assert node.docs_state == :pending
    assert node.session_metadata["code_commit_sha"] == node.git_commit_sha
    assert node.session_metadata["docs"]["state"] == "pending"
    assert node.session_metadata["docs"]["code_commit_sha"] == node.git_commit_sha
    assert SyncLedger.pushable(project.id, nil, 10) == []

    # The job finishes, pushes the node to its docs commit, then hands it to
    # the sync ledger (D5).
    assert eventually(fn -> Repo.get!(Node, node.id).docs_state == :current end)

    assert eventually(fn ->
             SyncLedger.pushable(project.id, nil, 10) |> Enum.any?(&(&1.id == node.id))
           end)
  end

  test "a schema present without a trigger skips docs",
       %{work_dir: work_dir, git_dir: git_dir, project: project} do
    Application.put_env(:cadence_daemon, :docs_enabled, false)
    on_exit(fn -> Application.delete_env(:cadence_daemon, :docs_enabled) end)

    queue =
      start_supervised!(
        {CommitQueue, [project_id: project.id, work_dir: work_dir, git_dir: git_dir]}
      )

    File.write!(Path.join(work_dir, ".caddocs.yaml"), @docs_schema)
    File.write!(Path.join(work_dir, "notes.txt"), "one\n")
    {:ok, _first} = CommitQueue.commit(queue, "schema")

    Application.delete_env(:cadence_daemon, :docs_enabled)

    File.write!(Path.join(work_dir, "notes.txt"), "two\n")
    {:ok, second} = CommitQueue.commit(queue, "notes")

    assert second.docs_state == :skipped
    refute Map.has_key?(second.session_metadata, "docs")
  end

  test "a schema parse error is recorded as shape-only metadata and never blocks",
       %{work_dir: work_dir, git_dir: git_dir, project: project} do
    queue =
      start_supervised!(
        {CommitQueue, [project_id: project.id, work_dir: work_dir, git_dir: git_dir]}
      )

    File.write!(Path.join(work_dir, ".caddocs.yaml"), "index_file: [unclosed\n")
    File.write!(Path.join(work_dir, "a.txt"), "hi\n")

    {:ok, node} = CommitQueue.commit(queue, "broken schema")

    assert node.docs_state == :skipped
    assert node.session_metadata["docs"]["state"] == "skipped"
    assert node.session_metadata["docs"]["error"] == "invalid_yaml"
  end

  test "a corrupt base tree does not crash the commit",
       %{work_dir: work_dir, git_dir: git_dir, project: project} do
    queue =
      start_supervised!(
        {CommitQueue, [project_id: project.id, work_dir: work_dir, git_dir: git_dir]}
      )

    File.write!(Path.join(work_dir, "a.txt"), "one\n")
    {:ok, first} = CommitQueue.commit(queue, "first")

    git = GitStore.init(git_dir, bare: true)
    tree = GitStore.read_commit(git, first.git_commit_sha).tree
    <<dir::binary-size(2)>> <> rest = tree
    File.rm!(Path.join([git.home_dir, "objects", dir, rest]))

    File.write!(Path.join(work_dir, "b.txt"), "two\n")
    {:ok, second} = CommitQueue.commit(queue, "second")

    assert second.parents == [first.id]
    assert second.docs_state == :skipped
  end

  test "a commit persists its sync row atomically",
       %{work_dir: work_dir, git_dir: git_dir, project: project} do
    queue =
      start_supervised!(
        {CommitQueue, [project_id: project.id, work_dir: work_dir, git_dir: git_dir]}
      )

    File.write!(Path.join(work_dir, "a.txt"), "hi\n")
    {:ok, node} = CommitQueue.commit(queue, "first")

    assert %SyncPending{} = pending = Repo.get(SyncPending, node.id)
    assert pending.project_id == project.id
  end

  defp insert_node(project, id, created_at) do
    %{
      id: id,
      project_id: project.id,
      git_commit_sha: String.duplicate("b", 40),
      parents: [],
      flags: [:"in-progress"],
      message: "m",
      created_by: project.owner_id,
      created_at: created_at,
      docs_state: :pending
    }
    |> Node.changeset()
    |> Repo.insert!()
  end
end
