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

    stored = Repo.get(Project, project.id)
    assert stored.slug == slug
    assert stored.created_at
    assert ProjectRegistry.lookup_queue(project.id) != nil

    assert [%{slug: ^slug, work_dir: ^work_dir}] =
             Projects.list_projects() |> Enum.filter(&(&1.slug == slug))

    assert project.id in Projects.list_project_ids()
  end

  test "register_project rejects an already-registered work_dir", %{work_dir: work_dir} do
    attrs = %{
      "name" => "Proj",
      "slug" => "proj-#{System.unique_integer([:positive])}",
      "work_dir" => work_dir
    }

    assert {:ok, _project} = Projects.register_project(attrs)
    assert {:error, :already_registered} = Projects.register_project(attrs)
  end

  test "register_project rejects a missing work_dir" do
    assert {:error, :missing_work_dir} =
             Projects.register_project(%{
               "name" => "x",
               "slug" => "x-#{System.unique_integer([:positive])}"
             })
  end
end
