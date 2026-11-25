defmodule Cadence.Daemon.DiscoveryTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import Cadence.Daemon.TestHelpers, only: [eventually: 1, eventually: 2]

  alias Cadence.Daemon.{
    Discovery,
    ImportFixture,
    Importer,
    ProjectLocation,
    ProjectRegistry,
    Projects,
    Repo
  }

  alias Cadence.Shared.{GitStore, Node, Project}

  setup do
    root = Path.join(System.tmp_dir!(), "cadence_hub_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "slugify normalizes directory names" do
    assert Discovery.slugify("My Project") == "my-project"
    assert Discovery.slugify("mise_tools") == "mise-tools"
    assert Discovery.slugify("A--B") == "a-b"
    assert Discovery.slugify("___") == "project"
  end

  test "initial scan registers direct child directories only", %{root: root} do
    suffix = System.unique_integer([:positive])
    alpha = "alpha-#{suffix}"
    beta = "beta-#{suffix}"
    hidden = ".hidden-#{suffix}"
    File.mkdir_p!(Path.join(root, alpha))
    File.mkdir_p!(Path.join([root, alpha, "nested"]))
    File.mkdir_p!(Path.join(root, beta))
    File.mkdir_p!(Path.join(root, hidden))
    File.write!(Path.join(root, "file.txt"), "x")

    pid = start_discovery(root)
    assert :ok = Discovery.scan_now(pid)

    assert %{slug: ^alpha} = alpha_project = location(Path.join(root, alpha))
    assert %{slug: ^beta} = location(Path.join(root, beta))
    assert location(Path.join(root, hidden)) == nil
    assert location(Path.join([root, alpha, "nested"])) == nil

    nodes = Repo.all(from(n in Node, where: n.project_id == ^alpha_project.id))
    assert [%{flags: [:imported], docs_state: :skipped}] = nodes

    stop_projects([Path.join(root, alpha), Path.join(root, beta)])
  end

  test "an already registered child is left alone", %{root: root} do
    suffix = System.unique_integer([:positive])
    name = "existing-#{suffix}"
    path = Path.join(root, name)
    File.mkdir_p!(path)

    slug = "existing-slug-#{suffix}"

    assert {:ok, _} =
             Projects.register_project(
               %{"name" => name, "slug" => slug, "work_dir" => path},
               watch: false
             )

    pid = start_discovery(root)
    assert :ok = Discovery.scan_now(pid)

    assert %{slug: ^slug} = location(path)
    assert Repo.get_by(Project, slug: name) == nil
  end

  test "a slug collision gets a numeric suffix", %{root: root} do
    suffix = System.unique_integer([:positive])
    base = "hub-slug-#{suffix}"
    child = Path.join(root, base)
    File.mkdir_p!(child)

    other = Path.join(root, "other-#{suffix}")
    File.mkdir_p!(other)

    assert {:ok, _} =
             Projects.register_project(%{"name" => base, "slug" => base, "work_dir" => other},
               watch: false
             )

    pid = start_discovery(root)
    assert :ok = Discovery.scan_now(pid)

    assert %{slug: slug} = location(child)
    assert slug == "#{base}-2"

    stop_projects([child])
  end

  test "a child that contains an existing project is skipped", %{root: root} do
    suffix = System.unique_integer([:positive])
    parent = Path.join(root, "parent-#{suffix}")
    nested = Path.join(parent, "nested")
    File.mkdir_p!(nested)

    assert {:ok, _} =
             Projects.register_project(
               %{
                 "name" => "nested-#{suffix}",
                 "slug" => "nested-#{suffix}",
                 "work_dir" => nested
               },
               watch: false
             )

    pid = start_discovery(root)
    assert :ok = Discovery.scan_now(pid)

    assert location(parent) == nil
  end

  test "the hub itself registered as a project skips its children", %{root: root} do
    suffix = System.unique_integer([:positive])
    child = Path.join(root, "child-#{suffix}")
    File.mkdir_p!(child)

    assert {:ok, _} =
             Projects.register_project(
               %{"name" => "hub-#{suffix}", "slug" => "hub-#{suffix}", "work_dir" => root},
               watch: false
             )

    pid = start_discovery(root)
    assert :ok = Discovery.scan_now(pid)

    assert location(child) == nil
  end

  test "a Git repository under the hub imports its history", %{root: root} do
    suffix = System.unique_integer([:positive])
    name = "repo-#{suffix}"
    files = %{"README.md" => "# repo\n", "lib/app.ex" => "defmodule App do\nend\n"}

    git = ImportFixture.worktree(root, name)
    first = ImportFixture.commit(git, %{"README.md" => "# repo\n"}, [], "initial")
    tip = ImportFixture.commit(git, files, [first], "second")
    ImportFixture.write_ref(git, "refs/heads/main", tip)
    ImportFixture.write_worktree(git, files)

    hub_path = Path.join(root, name)
    assert {:ok, %{kind: :worktree}} = GitStore.detect_repository(hub_path)

    pid = start_discovery(root)
    assert :ok = Discovery.scan_now(pid)

    assert eventually(fn -> location(hub_path) != nil end, 10_000)

    assert eventually(
             fn ->
               case Enum.find(Importer.list(), &(Path.expand(&1.source.path) == hub_path)) do
                 %{status: :completed} -> true
                 %{status: :failed} = job -> flunk("hub import failed: #{inspect(job.error)}")
                 _ -> false
               end
             end,
             15_000
           )

    project = location(hub_path)

    assert eventually(
             fn ->
               nodes = Repo.all(from(n in Node, where: n.project_id == ^project.id))
               imported = Enum.filter(nodes, & &1.session_metadata["import"])
               length(imported) == 2 and Enum.all?(imported, &(:imported in &1.flags))
             end,
             10_000
           )

    nodes = Repo.all(from(n in Node, where: n.project_id == ^project.id))
    imported = Enum.filter(nodes, & &1.session_metadata["import"])
    assert Enum.map(imported, & &1.git_commit_sha) |> Enum.sort() == Enum.sort([first, tip])
    assert Enum.all?(imported, &(&1.docs_state == :skipped))

    stop_projects([hub_path])
  end

  test "a directory created after boot is registered", %{root: root} do
    suffix = System.unique_integer([:positive])
    name = "later-#{suffix}"
    path = Path.join(root, name)

    pid = start_discovery(root)
    assert :ok = Discovery.scan_now(pid)
    assert location(path) == nil

    File.mkdir_p!(path)

    assert eventually(fn ->
             case location(path) do
               nil ->
                 false

               project ->
                 Repo.aggregate(from(n in Node, where: n.project_id == ^project.id), :count) == 1
             end
           end)

    stop_projects([path])
  end

  test "a missing root is retried", %{root: root} do
    suffix = System.unique_integer([:positive])
    hub = Path.join(root, "late-hub-#{suffix}")
    child = Path.join(hub, "child-#{suffix}")

    pid = start_discovery(hub)
    assert :ok = Discovery.scan_now(pid)
    assert Process.alive?(pid)

    File.mkdir_p!(child)

    assert eventually(
             fn ->
               case location(child) do
                 nil ->
                   false

                 project ->
                   Repo.aggregate(from(n in Node, where: n.project_id == ^project.id), :count) ==
                     1
               end
             end,
             5_000
           )

    stop_projects([child])
  end

  defp start_discovery(root) do
    start_supervised!(
      {Discovery,
       [
         root: root,
         backend: :fs_poll,
         interval: 50,
         scan_interval_ms: 100,
         name: nil
       ]}
    )
  end

  defp location(path) do
    case Repo.get_by(ProjectLocation, work_dir: Path.expand(path)) do
      nil -> nil
      location -> Repo.get(Project, location.project_id)
    end
  end

  defp stop_projects(paths) do
    Enum.each(paths, fn path ->
      case Repo.get_by(ProjectLocation, work_dir: Path.expand(path)) do
        nil -> :ok
        location -> ProjectRegistry.stop_project(location.project_id)
      end
    end)
  end
end
