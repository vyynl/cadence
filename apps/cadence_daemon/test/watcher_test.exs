defmodule Cadence.Daemon.WatcherTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  import Cadence.Daemon.TestHelpers, only: [eventually: 1]

  alias Cadence.Daemon.{CommitQueue, Repo, Watcher}
  alias Cadence.Daemon.TestHelpers
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
    baseline = Path.join(work_dir, "baseline.txt")
    File.write!(baseline, "baseline\n")

    queue =
      start_supervised!(
        {CommitQueue, [project_id: project.id, work_dir: work_dir, git_dir: git_dir]}
      )

    watcher =
      start_supervised!(
        {Watcher,
         [dir: work_dir, commit_queue: queue, backend: :fs_poll, interval: 50, debounce_ms: 50]}
      )

    # Wait until the poller has taken its baseline, so the next write is an event.
    TestHelpers.await_poll_baseline(watcher, baseline)

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
    baseline = Path.join(work_dir, "baseline.txt")
    File.write!(baseline, "baseline\n")

    watcher =
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

    TestHelpers.await_poll_baseline(watcher, baseline)

    assert :ok = Watcher.suspend(project.id)
    assert Watcher.suspended?(project.id)

    pid = GenServer.whereis(name)
    %{worker: worker} = :sys.get_state(pid)

    send(pid, {:file_event, worker, {Path.join(work_dir, "a.txt"), [:created]}})

    # Barrier: the event has been handled once the call returns. The matching
    # `handle_info/2` clause requires the backend pid, so a suspended watcher
    # must have hit the suspension branch and dropped it: no timer, no pending
    # commit.
    state = :sys.get_state(pid)
    assert state.timer == nil
    refute state.pending

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
    baseline = Path.join(work_dir, "baseline.txt")
    File.write!(baseline, "baseline\n")

    watcher =
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

    TestHelpers.await_poll_baseline(watcher, baseline)
    File.write!(Path.join(work_dir, "a.txt"), "hi\n")

    # The poller sees the write and arms the debounce; suspend before it fires.
    assert eventually(fn -> :sys.get_state(watcher).timer != nil end)
    assert :ok = Watcher.suspend(project.id)

    # Genuine debounce window: outlast the 400 ms debounce, so a timer that
    # escaped `cancel_timer/1` would have fired and created a node by now.
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
    baseline = Path.join(work_dir, "baseline.txt")
    File.write!(baseline, "baseline\n")

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

    # Wait until the poller has taken its baseline before removing the directory.
    TestHelpers.await_poll_baseline(pid, baseline)

    File.rm_rf!(work_dir)

    # The backend crashes on its next poll. The watcher must stay up (that is
    # what keeps the project supervisor from restarting it in a loop) and no
    # commit may be attempted against the missing tree. Wait for the backend
    # exit itself instead of assuming a poll interval.
    assert eventually(fn -> TestHelpers.watcher_backend_down?(pid) end)
    assert Process.alive?(pid)
    refute Watcher.suspended?(project.id)
    assert count_nodes(project) == 0

    # Recreate the directory with the baseline marker already inside, in one
    # rename: the reconnected poller takes its baseline with the marker present,
    # so recovery cannot create a node of its own and the next write is the only
    # commit this assertion can see.
    recovered = work_dir <> ".recovered"
    File.mkdir_p!(recovered)
    File.write!(Path.join(recovered, "baseline.txt"), "baseline\n")
    File.rename!(recovered, work_dir)
    TestHelpers.await_poll_baseline(pid, baseline)

    before_count = count_nodes(project)
    File.write!(Path.join(work_dir, "back.txt"), "hi\n")

    assert eventually(fn -> count_nodes(project) == before_count + 1 end)
  end

  defp count_nodes(project) do
    Repo.aggregate(where(Node, [n], n.project_id == ^project.id), :count)
  end
end
