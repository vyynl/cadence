defmodule Cadence.Daemon.API.IntegrationTest do
  use ExUnit.Case, async: false

  alias Cadence.Daemon.{API, Client, CommitQueue, ProjectRegistry, Session}

  setup do
    root = Path.join(System.tmp_dir!(), "cadence_api_#{System.unique_integer([:positive])}")
    socket = Path.join(root, "daemon.sock")
    work_dir = Path.join(root, "work")
    File.mkdir_p!(work_dir)
    on_exit(fn -> File.rm_rf!(root) end)
    %{socket: socket, work_dir: work_dir}
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

    assert %{"project" => %{"slug" => ^slug, "name" => "Release"}} =
             Cadence.Daemon.Release.register("Release", slug, work_dir, socket)

    %{status: 200, body: %{"projects" => projects}} =
      Client.request("GET", "/projects", nil, socket)

    assert Enum.any?(projects, &(&1["slug"] == slug))
  end
end
