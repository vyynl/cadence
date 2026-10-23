defmodule Cadence.Daemon.SyncClientTest do
  use ExUnit.Case, async: false

  alias Cadence.Daemon.SyncClient
  alias Cadence.Shared.Project

  @token "cad-test-token"

  setup do
    on_exit(fn ->
      Enum.each(
        [:server_url, :auth_token, :sync_request_timeout_ms, :sync_req_options],
        &Application.delete_env(:cadence_daemon, &1)
      )
    end)

    :ok
  end

  test "me/0 sends the bearer token and returns the user ID" do
    configure()
    user_id = Ecto.UUID.generate()

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/sync/me"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{@token}"]
      Req.Test.json(conn, %{user_id: user_id, email: "u@example.com", name: "u"})
    end)

    assert SyncClient.me() == {:ok, user_id}
  end

  test "push/1 posts encoded nodes and returns mappings" do
    configure()

    nodes = [
      %{
        "id" => Ecto.UUID.generate(),
        "project_id" => Ecto.UUID.generate(),
        "git_commit_sha" => String.duplicate("a", 40),
        "parents" => [],
        "flags" => ["in-progress"],
        "pinned" => false,
        "message" => "m",
        "session_metadata" => %{},
        "created_by" => Ecto.UUID.generate(),
        "created_at" => "2026-10-23T12:00:00.000000Z",
        "docs_state" => "pending",
        "git_objects" => []
      }
    ]

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/sync/nodes"
      assert conn.body_params == %{"nodes" => nodes}
      Req.Test.json(conn, %{mappings: [%{local_id: hd(nodes)["id"], cloud_id: hd(nodes)["id"]}]})
    end)

    assert {:ok, %{mappings: [%{"local_id" => local_id, "cloud_id" => cloud_id}]}} =
             SyncClient.push(nodes)

    assert local_id == hd(nodes)["id"]
    assert cloud_id == hd(nodes)["id"]
  end

  test "pull/2 sends project and cursor parameters" do
    configure()
    project_id = Ecto.UUID.generate()

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/sync/nodes"
      assert conn.query_params["project_id"] == project_id
      assert conn.query_params["since"] == "42"
      Req.Test.json(conn, %{nodes: [], cursor: "42"})
    end)

    assert SyncClient.pull(project_id, "42") == {:ok, %{nodes: [], cursor: "42"}}
  end

  test "provision/1 posts the local project identity" do
    configure()
    project_id = Ecto.UUID.generate()

    project = %Project{
      id: project_id,
      name: "My Project",
      slug: "my-project",
      owner_id: Ecto.UUID.generate(),
      created_at: DateTime.utc_now()
    }

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/sync/projects"

      assert conn.body_params == %{
               "project" => %{"id" => project_id, "name" => "My Project", "slug" => "my-project"}
             }

      Req.Test.json(conn, %{project: %{id: project_id, name: "My Project", slug: "my-project"}})
    end)

    assert {:ok, %{"id" => ^project_id}} = SyncClient.provision(project)
  end

  test "returns HTTP errors without retrying" do
    configure()

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(403, Jason.encode!(%{error: "not a project member"}))
    end)

    assert SyncClient.me() == {:error, {:http, 403, %{"error" => "not a project member"}}}
  end

  test "returns transport errors" do
    configure()

    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert {:error, %Req.TransportError{reason: :timeout}} = SyncClient.me()
  end

  test "reports offline mode when URL or token is missing" do
    refute SyncClient.configured?()
    assert SyncClient.me() == {:error, :not_configured}
  end

  defp configure do
    Application.put_env(:cadence_daemon, :server_url, "https://cadence.test")
    Application.put_env(:cadence_daemon, :auth_token, @token)
    Application.put_env(:cadence_daemon, :sync_req_options, plug: {Req.Test, __MODULE__})
  end
end
