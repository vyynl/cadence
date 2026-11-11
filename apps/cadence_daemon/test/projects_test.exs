defmodule Cadence.Daemon.ProjectsTest do
  use ExUnit.Case, async: false

  alias Cadence.Daemon.{ProjectLocation, ProjectRegistry, Projects, Repo}
  alias Cadence.Shared.{GitStore, Project}

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

  test "register_project watch: false persists without booting the pair", %{work_dir: work_dir} do
    slug = "proj-#{System.unique_integer([:positive])}"

    assert {:ok, project} =
             Projects.register_project(
               %{"name" => "Proj", "slug" => slug, "work_dir" => work_dir},
               watch: false
             )

    assert Repo.get(ProjectLocation, project.id)
    assert ProjectRegistry.lookup_queue(project.id) == nil
  end

  test "rehydrate leaves a bare imported project data-only", %{work_dir: work_dir} do
    bare = GitStore.init(Path.join(work_dir, "bare.git"), bare: true)
    File.write!(Path.join(bare.home_dir, "HEAD"), "ref: refs/heads/main\n")

    slug = "proj-#{System.unique_integer([:positive])}"

    assert {:ok, project} =
             Projects.register_project(
               %{"name" => "Bare", "slug" => slug, "work_dir" => bare.home_dir},
               watch: false
             )

    assert {:ok, %{kind: :bare}} = GitStore.detect_repository(bare.home_dir)
    assert ProjectRegistry.lookup_queue(project.id) == nil
    assert :ok = Projects.rehydrate()
    assert ProjectRegistry.lookup_queue(project.id) == nil
  end

  test "register_project rejects a missing work_dir" do
    assert {:error, :missing_work_dir} =
             Projects.register_project(%{
               "name" => "x",
               "slug" => "x-#{System.unique_integer([:positive])}"
             })
  end
end
