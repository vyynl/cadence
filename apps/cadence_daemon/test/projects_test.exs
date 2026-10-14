defmodule Cadence.Daemon.ProjectsTest do
  use ExUnit.Case, async: false

  alias Cadence.Daemon.{ProjectRegistry, Projects, Repo}
  alias Cadence.Shared.Project

  setup do
    root = Path.join(System.tmp_dir!(), "cadence_proj_#{System.unique_integer([:positive])}")
    work_dir = Path.join(root, "work")
    File.mkdir_p!(work_dir)
    on_exit(fn -> File.rm_rf!(root) end)
    %{work_dir: work_dir}
  end

  test "register_project persists and boots a queue", %{work_dir: work_dir} do
    slug = "proj-#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.register_project(%{"name" => "Proj", "slug" => slug, "work_dir" => work_dir})

    assert Repo.get(Project, project.id).slug == slug
    assert ProjectRegistry.lookup_queue(project.id) != nil

    assert [%{slug: ^slug, work_dir: ^work_dir}] =
             Projects.list_projects() |> Enum.filter(&(&1.slug == slug))
  end

  test "register_project rejects a missing work_dir" do
    assert {:error, :missing_work_dir} =
             Projects.register_project(%{
               "name" => "x",
               "slug" => "x-#{System.unique_integer([:positive])}"
             })
  end
end
