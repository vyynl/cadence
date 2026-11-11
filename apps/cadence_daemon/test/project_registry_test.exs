defmodule Cadence.Daemon.ProjectRegistryTest do
  use ExUnit.Case, async: false

  import Cadence.Daemon.TestHelpers, only: [eventually: 1]

  alias Cadence.Daemon.{CommitQueue, ProjectRegistry, Repo}
  alias Cadence.Daemon.TestHelpers
  alias Cadence.Shared.Project

  setup do
    root = Path.join(System.tmp_dir!(), "cadence_reg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    %{root: root}
  end

  test "stop_project/1 stops the project's queue and watcher", %{root: root} do
    on_exit(fn -> File.rm_rf!(root) end)
    project = insert_project()
    work_dir = Path.join(root, "work")
    File.mkdir_p!(work_dir)

    {:ok, _sup} = start_project(project, work_dir, root)
    queue = ProjectRegistry.lookup_queue(project.id)
    assert is_pid(queue)

    assert :ok = ProjectRegistry.stop_project(project.id)
    assert eventually(fn -> not Process.alive?(queue) end)
    assert eventually(fn -> ProjectRegistry.lookup_queue(project.id) == nil end)
    assert :ok = ProjectRegistry.stop_project(project.id)
  end

  test "a vanished project directory does not take down another project", %{root: root} do
    first = insert_project()
    second = insert_project()
    first_dir = Path.join(root, "first")
    second_dir = Path.join(root, "second")
    File.mkdir_p!(first_dir)
    File.mkdir_p!(second_dir)

    on_exit(fn ->
      ProjectRegistry.stop_project(first.id)
      ProjectRegistry.stop_project(second.id)
      File.rm_rf!(root)
    end)

    {:ok, first_sup} = start_project(first, first_dir, root)
    {:ok, _second_sup} = start_project(second, second_dir, root)

    first_queue = ProjectRegistry.lookup_queue(first.id)
    second_queue = ProjectRegistry.lookup_queue(second.id)
    assert is_pid(first_queue)
    assert is_pid(second_queue)

    # The poller's next cycle crashes once the directory is gone. Under the old
    # linked-watcher layout this restarted the project supervisor until the
    # registry itself was terminated (dropping every project).
    File.rm_rf!(first_dir)

    first_watcher = {:via, Registry, {Cadence.Daemon.Queues, {:watcher, first.id}}}
    assert eventually(fn -> TestHelpers.watcher_backend_down?(first_watcher) end)

    assert Process.alive?(first_sup)
    assert Process.alive?(first_queue)
    assert ProjectRegistry.lookup_queue(first.id) == first_queue
    assert ProjectRegistry.lookup_queue(second.id) == second_queue

    assert {:ok, node} = CommitQueue.commit(second_queue, "still works")
    assert node.project_id == second.id
  end

  defp start_project(project, work_dir, root) do
    baseline = Path.join(work_dir, "baseline.txt")
    File.write!(baseline, "baseline\n")

    {:ok, sup} =
      ProjectRegistry.start_project(
        project_id: project.id,
        work_dir: work_dir,
        git_dir: Path.join(root, "git-#{project.id}"),
        backend: :fs_poll,
        interval: 20,
        debounce_ms: 20,
        reconnect_ms: 20
      )

    TestHelpers.await_poll_baseline(
      {:via, Registry, {Cadence.Daemon.Queues, {:watcher, project.id}}},
      baseline
    )

    {:ok, sup}
  end

  defp insert_project do
    %{
      name: "p",
      slug: "p-#{System.unique_integer([:positive])}",
      owner_id: Ecto.UUID.generate()
    }
    |> Project.changeset()
    |> Repo.insert!()
  end
end
