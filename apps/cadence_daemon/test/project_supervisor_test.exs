defmodule Cadence.Daemon.ProjectSupervisorTest do
  use ExUnit.Case, async: false

  alias Cadence.Daemon.{ProjectRegistry, ProjectSupervisor}

  test "supervises the commit queue and watcher as one unit" do
    root = Path.join(System.tmp_dir!(), "cadence_psup_#{System.unique_integer([:positive])}")
    work_dir = Path.join(root, "work")
    git_dir = Path.join(root, "git")
    File.mkdir_p!(work_dir)
    on_exit(fn -> File.rm_rf!(root) end)

    project_id = Ecto.UUID.generate()

    sup =
      start_supervised!(
        {ProjectSupervisor,
         [
           project_id: project_id,
           work_dir: work_dir,
           git_dir: git_dir,
           backend: :fs_poll,
           interval: 50
         ]}
      )

    assert length(Supervisor.which_children(sup)) == 2
    assert ProjectRegistry.lookup_queue(project_id) != nil
  end
end
