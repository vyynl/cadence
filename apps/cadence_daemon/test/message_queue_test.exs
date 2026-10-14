defmodule Cadence.Daemon.MessageQueueTest do
  use ExUnit.Case, async: false

  alias Cadence.Daemon.{CommitQueue, MessageQueue, ProjectLocation, Repo}
  alias Cadence.Shared.{Node, Project}

  setup do
    root = Path.join(System.tmp_dir!(), "cadence_mq_#{System.unique_integer([:positive])}")
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

    queue =
      start_supervised!(
        {CommitQueue, [project_id: project.id, work_dir: work_dir, git_dir: git_dir]}
      )

    on_exit(fn -> File.rm_rf!(root) end)

    %{project: project, work_dir: work_dir, queue: queue}
  end

  test "retries a pending node and applies the generated message",
       %{project: project, work_dir: work_dir, queue: queue} do
    Application.put_env(:cadence_daemon, :llm, Cadence.Daemon.TestLLM)

    Application.put_env(
      :cadence_daemon,
      :test_llm_result,
      {:ok, "SUMMARY: Retried\nFLAG: broken\n"}
    )

    Application.put_env(:cadence_daemon, :llm_retry_backoff_ms, 10)

    on_exit(fn ->
      Application.delete_env(:cadence_daemon, :llm)
      Application.delete_env(:cadence_daemon, :test_llm_result)
      Application.delete_env(:cadence_daemon, :llm_retry_backoff_ms)
    end)

    File.write!(Path.join(work_dir, "a.txt"), "content\n")

    {:ok, node} = CommitQueue.commit(queue, "placeholder")

    {:ok, _node} =
      node
      |> Node.changeset(%{session_metadata: %{"message_pending" => true}})
      |> Repo.update()

    MessageQueue.enqueue(project.id, node.id)

    assert eventually(fn ->
             loaded = Repo.get!(Node, node.id)

             loaded.message == "Retried" and
               not Map.has_key?(loaded.session_metadata, "message_pending")
           end)

    loaded = Repo.get!(Node, node.id)
    assert loaded.flags == [:broken]
    assert loaded.session_metadata == %{"model" => "test-model"}
  end

  defp eventually(fun, timeout \\ 3000) do
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
