defmodule Cadence.Daemon.TUI.ClientTest do
  use ExUnit.Case, async: false

  alias Cadence.Daemon.{API, Client, CommitQueue, ProjectRegistry, Session}

  alias Cadence.Daemon.TUI.Client, as: TUIClient

  setup do
    root =
      Path.join(System.tmp_dir!(), "cadence_tui_client_#{System.unique_integer([:positive])}")

    socket = Path.join(root, "daemon.sock")
    work_dir = Path.join(root, "work")
    File.mkdir_p!(work_dir)
    on_exit(fn -> File.rm_rf!(root) end)
    %{socket: socket, work_dir: work_dir}
  end

  defp register(socket, work_dir) do
    slug = "tui-#{System.unique_integer([:positive])}"

    %{status: 201, body: %{"project" => project}} =
      Client.request(
        "POST",
        "/projects",
        %{"name" => "TUI", "slug" => slug, "work_dir" => work_dir},
        socket
      )

    on_exit(fn -> ProjectRegistry.stop_project(project["id"]) end)
    project
  end

  test "health, projects, and graph round-trip over the socket", %{
    socket: socket,
    work_dir: work_dir
  } do
    start_supervised!({API, socket_path: socket})
    project = register(socket, work_dir)

    assert {:ok, %{"status" => "ok"}} = TUIClient.health(socket_path: socket)

    assert {:ok, %{"projects" => projects}} = TUIClient.projects(socket_path: socket)
    assert Enum.any?(projects, &(&1["slug"] == project["slug"]))

    queue = ProjectRegistry.lookup_queue(project["id"])
    {:ok, node} = CommitQueue.commit(queue, "first")
    {:ok, _} = Session.switch(project["id"], node.id)

    assert {:ok, graph} = TUIClient.graph(project["id"], socket_path: socket)
    assert graph["default_node_id"] == node.id
    assert [%{"id" => id}] = graph["nodes"]
    assert id == node.id
    assert graph["edges"] == []
  end

  test "diff, switch, spawn, and proposals round-trip", %{socket: socket, work_dir: work_dir} do
    start_supervised!({API, socket_path: socket})
    project = register(socket, work_dir)

    # The watcher would race the explicit commits; suspend it for the fixture.
    :ok = Cadence.Daemon.Watcher.suspend(project["id"], :tui_test)
    on_exit(fn -> Cadence.Daemon.Watcher.resume(project["id"], :tui_test) end)

    File.write!(Path.join(work_dir, "a.txt"), "hello\n")

    queue = ProjectRegistry.lookup_queue(project["id"])
    {:ok, node} = CommitQueue.commit(queue, "first")
    {:ok, _} = Session.switch(project["id"], node.id)

    assert {:ok, %{"files" => files} = diff} =
             TUIClient.diff(project["id"], node.id, socket_path: socket)

    assert diff["node_id"] == node.id
    assert Enum.any?(files, &(&1["path"] == "a.txt" and &1["status"] == "added"))

    assert {:ok, %{"session_pointer" => pointer}} =
             TUIClient.switch(project["id"], node.id, socket_path: socket)

    assert pointer == node.id

    assert {:ok, %{"node" => spawned}} =
             TUIClient.spawn(project["id"], "explore", socket_path: socket)

    assert spawned["parents"] == [node.id]
    assert spawned["flags"] == ["sandbox"]

    assert {:ok, %{"proposals" => []}} =
             TUIClient.proposals(project["id"], socket_path: socket)
  end

  test "docs endpoints map the skipped and 409 responses", %{socket: socket, work_dir: work_dir} do
    start_supervised!({API, socket_path: socket})
    project = register(socket, work_dir)

    queue = ProjectRegistry.lookup_queue(project["id"])
    {:ok, node} = CommitQueue.commit(queue, "first")
    {:ok, _} = Session.switch(project["id"], node.id)

    assert {:ok, %{"status" => "skipped", "reason" => reason}} =
             TUIClient.docs_sync(project["id"], node.id, socket_path: socket)

    assert is_binary(reason)

    assert {:error, %{status: 409, message: message}} =
             TUIClient.docs_diff(project["id"], node.id, socket_path: socket)

    assert message =~ "docs"
  end

  test "missing projects and nodes map their HTTP errors", %{socket: socket} do
    start_supervised!({API, socket_path: socket})

    assert {:error, %{status: 404, message: "project not found"}} =
             TUIClient.graph("00000000-0000-4000-8000-000000000000", socket_path: socket)

    assert {:error, %{status: 404}} =
             TUIClient.graph("not-a-uuid", socket_path: socket)
  end

  test "a missing socket is reported as unreachable" do
    missing =
      Path.join(System.tmp_dir!(), "cadence-missing-#{System.unique_integer([:positive])}.sock")

    assert {:error, %{status: :unreachable, message: message}} =
             TUIClient.health(socket_path: missing)

    assert message =~ "unreachable"
  end

  test "a union with no server configured maps the 503", %{socket: socket, work_dir: work_dir} do
    start_supervised!({API, socket_path: socket})
    project = register(socket, work_dir)
    queue = ProjectRegistry.lookup_queue(project["id"])
    {:ok, first} = CommitQueue.commit(queue, "first")
    {:ok, second} = CommitQueue.spawn(queue, "branch")

    assert {:error, %{status: 503}} =
             TUIClient.union(project["id"], [first.id, second.id], socket_path: socket)
  end

  test "an invalid JSON body is reported as an invalid response" do
    path = serve_once("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nnot json")

    assert {:error, %{status: :invalid_response, message: message}} =
             TUIClient.health(socket_path: path)

    assert message =~ "invalid daemon response"
  end

  test "error bodies without a usable message fall back" do
    path = serve_once("HTTP/1.1 500 Server Error\r\nConnection: close\r\n\r\n{}")

    assert {:error, %{status: 500, message: "request failed"}} =
             TUIClient.health(socket_path: path)

    path = serve_once("HTTP/1.1 500 Server Error\r\nConnection: close\r\n\r\n")

    assert {:error, %{status: 500, message: "empty response"}} =
             TUIClient.health(socket_path: path)

    path = serve_once("HTTP/1.1 500 Server Error\r\nConnection: close\r\n\r\n{\"error\":{}}")

    assert {:error, %{status: 500, message: "request failed"}} =
             TUIClient.health(socket_path: path)
  end

  test "the typed client defaults to the daemon's own socket path" do
    # In the test env no API listens on the default path, so every default-arity
    # entry point reports unreachable instead of raising.
    assert {:error, %{status: :unreachable}} = TUIClient.health()
    assert {:error, %{status: :unreachable}} = TUIClient.projects()
    assert {:error, %{status: :unreachable}} = TUIClient.graph("p1")
    assert {:error, %{status: :unreachable}} = TUIClient.diff("p1", "n1")
    assert {:error, %{status: :unreachable}} = TUIClient.switch("p1", "n1")
    assert {:error, %{status: :unreachable}} = TUIClient.spawn("p1", "name")
    assert {:error, %{status: :unreachable}} = TUIClient.union("p1", ["a", "b"])
    assert {:error, %{status: :unreachable}} = TUIClient.proposals("p1")
    assert {:error, %{status: :unreachable}} = TUIClient.docs_sync("p1", nil)
    assert {:error, %{status: :unreachable}} = TUIClient.docs_diff("p1", nil)
  end

  test "a malformed status line is reported as an invalid response" do
    path = serve_once("HTTP/1.1 ABC\r\nConnection: close\r\n\r\n{}")

    assert {:error, %{status: :invalid_response}} = TUIClient.health(socket_path: path)
  end

  test "a daemon that never replies times out instead of hanging" do
    path =
      Path.join(
        System.tmp_dir!(),
        "cadence-tui-silent-#{System.unique_integer([:positive])}.sock"
      )

    on_exit(fn -> File.rm(path) end)

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, {:ifaddr, {:local, path}}, active: false, reuseaddr: true])

    spawn_link(fn ->
      {:ok, client} = :gen_tcp.accept(listen)
      {:ok, _request} = :gen_tcp.recv(client, 0)

      receive do
        :stop -> :ok
      after
        5_000 -> :ok
      end

      :gen_tcp.close(client)
      :gen_tcp.close(listen)
    end)

    assert {:error, %{status: :unreachable, message: message}} =
             TUIClient.health(socket_path: path, timeout: 50)

    assert message =~ "timed out"
  end

  # Serves one canned HTTP response on a fresh Unix socket.
  defp serve_once(response) do
    path =
      Path.join(
        System.tmp_dir!(),
        "cadence-tui-resp-#{System.unique_integer([:positive])}.sock"
      )

    on_exit(fn -> File.rm(path) end)

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, {:ifaddr, {:local, path}}, active: false, reuseaddr: true])

    spawn_link(fn ->
      {:ok, client} = :gen_tcp.accept(listen)
      {:ok, _request} = :gen_tcp.recv(client, 0)
      :ok = :gen_tcp.send(client, response)
      :gen_tcp.close(client)
      :gen_tcp.close(listen)
    end)

    path
  end
end
