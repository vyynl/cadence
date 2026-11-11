defmodule Cadence.Daemon.API.IntegrationTest do
  use ExUnit.Case, async: false

  alias Cadence.Daemon.{
    API,
    Client,
    CommitQueue,
    ImportClient,
    ImportFixture,
    ProjectRegistry,
    Release,
    Session
  }

  setup do
    root = Path.join(System.tmp_dir!(), "cadence_api_#{System.unique_integer([:positive])}")
    socket = Path.join(root, "daemon.sock")
    work_dir = Path.join(root, "work")
    File.mkdir_p!(work_dir)
    on_exit(fn -> File.rm_rf!(root) end)
    %{socket: socket, work_dir: work_dir, root: root}
  end

  test "binds an owner-only socket and serves a register → commit → switch → spawn round trip",
       %{socket: socket, work_dir: work_dir} do
    start_supervised!({API, socket_path: socket})

    assert Bitwise.band(File.stat!(socket).mode, 0o777) == 0o600

    slug = "api-#{System.unique_integer([:positive])}"

    %{status: 201, body: %{"project" => %{"id" => project_id}}} =
      Client.request(
        "POST",
        "/projects",
        %{"name" => "API", "slug" => slug, "work_dir" => work_dir},
        socket
      )

    on_exit(fn -> ProjectRegistry.stop_project(project_id) end)

    %{status: 200, body: %{"projects" => projects}} =
      Client.request("GET", "/projects", nil, socket)

    assert Enum.any?(projects, &(&1["slug"] == slug))

    # Seed a current node (empty tree, so no watcher events are fired).
    queue = ProjectRegistry.lookup_queue(project_id)
    {:ok, first} = CommitQueue.commit(queue, "first")
    {:ok, _} = Session.switch(project_id, first.id)

    %{status: 201, body: %{"node" => node}} =
      Client.request("POST", "/spawn", %{"project_id" => project_id, "name" => "explore"}, socket)

    assert node["flags"] == ["sandbox"]
    assert node["parents"] == [first.id]

    %{status: 200, body: %{"nodes" => nodes}} =
      Client.request("GET", "/nodes?project_id=#{project_id}", nil, socket)

    assert length(nodes) == 2
  end

  test "Release.register/4 registers through the socket (release equivalent of mix cad.register)",
       %{socket: socket, work_dir: work_dir} do
    start_supervised!({API, socket_path: socket})

    slug = "release-#{System.unique_integer([:positive])}"

    assert %{"project" => %{"slug" => ^slug, "name" => "Release"} = project} =
             Cadence.Daemon.Release.register("Release", slug, work_dir, socket)

    on_exit(fn -> ProjectRegistry.stop_project(project["id"]) end)

    %{status: 200, body: %{"projects" => projects}} =
      Client.request("GET", "/projects", nil, socket)

    assert Enum.any?(projects, &(&1["slug"] == slug))
  end

  test "imports a repository over the socket and serves job state", %{
    socket: socket,
    work_dir: work_dir
  } do
    start_supervised!({API, socket_path: socket})

    _git = worktree_with_history(work_dir)
    slug = "api-import-#{System.unique_integer([:positive])}"

    %{status: 202, body: %{"job" => job}} =
      Client.request(
        "POST",
        "/import",
        %{"work_dir" => work_dir, "name" => "API Import", "slug" => slug},
        socket
      )

    assert job["status"] in ["queued", "running"]
    assert job["project_slug"] == slug
    assert job["total"] == 2

    assert {:ok, final} = ImportClient.wait(job["id"], socket, 10_000)
    assert final["status"] == "completed"
    assert final["imported"] == 2

    on_exit(fn -> ProjectRegistry.stop_project(final["project_id"]) end)

    %{status: 200, body: %{"nodes" => nodes}} =
      Client.request("GET", "/nodes?project_id=#{final["project_id"]}", nil, socket)

    assert length(nodes) == 2

    assert %{status: 422} =
             Client.request(
               "POST",
               "/import",
               %{"work_dir" => Path.join(work_dir, "missing")},
               socket
             )

    assert %{status: 404} =
             Client.request("GET", "/import/#{Ecto.UUID.generate()}", nil, socket)
  end

  test "Release.import/3 runs through the same socket path", %{socket: socket, work_dir: work_dir} do
    start_supervised!({API, socket_path: socket})
    _git = worktree_with_history(work_dir)
    slug = "release-import-#{System.unique_integer([:positive])}"

    job = Release.import(work_dir, [name: "Release Import", slug: slug], socket)

    assert job["status"] == "completed"
    assert job["imported"] == 2
    on_exit(fn -> ProjectRegistry.stop_project(job["project_id"]) end)
  end

  defp worktree_with_history(work_dir) do
    git = ImportFixture.worktree(Path.dirname(work_dir))

    first = ImportFixture.commit(git, %{"README.md" => "one"}, [], "one", 1_600_000_000)
    second = ImportFixture.commit(git, %{"README.md" => "two"}, [first], "two", 1_600_000_100)
    ImportFixture.write_ref(git, "refs/heads/main", second)
    ImportFixture.write_worktree(git, %{"README.md" => "two"})

    git
  end
end
