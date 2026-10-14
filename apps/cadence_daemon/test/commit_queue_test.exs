defmodule Cadence.Daemon.CommitQueueTest do
  use ExUnit.Case, async: false

  alias Cadence.Daemon.{CommitQueue, Repo, Session}
  alias Cadence.Shared.{GitStore, Project}

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

    assert node.message == "Generated\n\n- x"
    assert node.flags == [:"in-progress"]
    assert node.session_metadata == %{"model" => "test-model"}
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
end
