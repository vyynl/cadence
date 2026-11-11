defmodule Cadence.Daemon.WatcherTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Cadence.Daemon.{CommitQueue, Repo, Watcher}
  alias Cadence.Shared.{Node, Project}

  setup do
    root = Path.join(System.tmp_dir!(), "cadence_watch_#{System.unique_integer([:positive])}")
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

  test "a file change triggers a debounced commit",
       %{work_dir: work_dir, git_dir: git_dir, project: project} do
    queue =
      start_supervised!(
        {CommitQueue, [project_id: project.id, work_dir: work_dir, git_dir: git_dir]}
      )

    start_supervised!(
      {Watcher,
       [dir: work_dir, commit_queue: queue, backend: :fs_poll, interval: 50, debounce_ms: 50]}
    )

    # Let the poller establish its baseline before writing.
    Process.sleep(300)

    File.write!(Path.join(work_dir, "hello.txt"), "hi\n")

    assert eventually(fn ->
             Repo.aggregate(where(Node, [n], n.project_id == ^project.id), :count) == 1
           end)
  end

  test "suspension drops events and resume re-arms commits",
       %{work_dir: work_dir, git_dir: git_dir, project: project} do
    queue =
      start_supervised!(
        {CommitQueue, [project_id: project.id, work_dir: work_dir, git_dir: git_dir]}
      )

    name = {:via, Registry, {Cadence.Daemon.Queues, {:watcher, project.id}}}

    start_supervised!(
      {Watcher,
       [
         dir: work_dir,
         commit_queue: queue,
         backend: :fs_poll,
         interval: 50,
         debounce_ms: 50,
         name: name
       ]}
    )

    Process.sleep(300)

    assert :ok = Watcher.suspend(project.id)
    assert Watcher.suspended?(project.id)

    send(
      GenServer.whereis(name),
      {:file_event, self(), {Path.join(work_dir, "a.txt"), [:created]}}
    )

    Process.sleep(200)

    assert count_nodes(project) == 0

    assert :ok = Watcher.resume(project.id)
    refute Watcher.suspended?(project.id)

    File.write!(Path.join(work_dir, "a.txt"), "hi\n")
    assert eventually(fn -> count_nodes(project) == 1 end)
  end

  test "resume re-arms a commit that was pending before suspension",
       %{work_dir: work_dir, git_dir: git_dir, project: project} do
    queue =
      start_supervised!(
        {CommitQueue, [project_id: project.id, work_dir: work_dir, git_dir: git_dir]}
      )

    name = {:via, Registry, {Cadence.Daemon.Queues, {:watcher, project.id}}}

    start_supervised!(
      {Watcher,
       [
         dir: work_dir,
         commit_queue: queue,
         backend: :fs_poll,
         interval: 50,
         debounce_ms: 400,
         name: name
       ]}
    )

    Process.sleep(300)
    File.write!(Path.join(work_dir, "a.txt"), "hi\n")

    # The poller sees the write and arms the debounce; suspend before it fires.
    Process.sleep(150)
    assert :ok = Watcher.suspend(project.id)

    Process.sleep(500)
    assert count_nodes(project) == 0

    assert :ok = Watcher.resume(project.id)
    assert eventually(fn -> count_nodes(project) == 1 end)
  end

  test "suspension is token-scoped", %{work_dir: work_dir, git_dir: git_dir, project: project} do
    queue =
      start_supervised!(
        {CommitQueue, [project_id: project.id, work_dir: work_dir, git_dir: git_dir]}
      )

    name = {:via, Registry, {Cadence.Daemon.Queues, {:watcher, project.id}}}

    start_supervised!(
      {Watcher,
       [
         dir: work_dir,
         commit_queue: queue,
         backend: :fs_poll,
         interval: 50,
         debounce_ms: 50,
         name: name
       ]}
    )

    assert :ok = Watcher.suspend(project.id, :docs)
    assert :ok = Watcher.suspend(project.id, {:import, "job"})
    assert Watcher.suspended?(project.id)

    assert :ok = Watcher.resume(project.id, :docs)
    assert Watcher.suspended?(project.id)

    assert :ok = Watcher.resume(project.id, {:import, "job"})
    refute Watcher.suspended?(project.id)
  end

  test "survives a vanished project directory and resumes when it returns",
       %{work_dir: work_dir, git_dir: git_dir, project: project} do
    queue =
      start_supervised!(
        {CommitQueue, [project_id: project.id, work_dir: work_dir, git_dir: git_dir]}
      )

    name = {:via, Registry, {Cadence.Daemon.Queues, {:watcher, project.id}}}

    pid =
      start_supervised!(
        {Watcher,
         [
           dir: work_dir,
           commit_queue: queue,
           backend: :fs_poll,
           interval: 50,
           debounce_ms: 50,
           reconnect_ms: 50,
           name: name
         ]}
      )

    # Let the poller establish its baseline before removing the directory.
    Process.sleep(300)

    File.rm_rf!(work_dir)

    # The backend crashes on its next poll. The watcher must stay up (that is
    # what keeps the project supervisor from restarting it in a loop) and no
    # commit may be attempted against the missing tree.
    Process.sleep(400)
    assert Process.alive?(pid)
    refute Watcher.suspended?(project.id)
    assert count_nodes(project) == 0

    File.mkdir_p!(work_dir)
    Process.sleep(300)
    File.write!(Path.join(work_dir, "back.txt"), "hi\n")

    assert eventually(fn -> count_nodes(project) == 1 end)
  end

  defp count_nodes(project) do
    Repo.aggregate(where(Node, [n], n.project_id == ^project.id), :count)
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
        Process.sleep(50)
        try_until(fun, deadline)
      end
    end
  end
end
