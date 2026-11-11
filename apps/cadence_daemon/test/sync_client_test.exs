defmodule Cadence.Daemon.SyncClientTest do
  use ExUnit.Case, async: false

  alias Cadence.Daemon.SyncClient
  alias Cadence.Shared.Project
  alias Cadence.Shared.Sync.PushPreferences

  @token "cad-test-token"

  setup do
    on_exit(fn ->
      Enum.each(
        [
          :server_url,
          :auth_token,
          :sync_request_timeout_ms,
          :sync_union_timeout_ms,
          :sync_req_options
        ],
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

    assert SyncClient.pull(project_id, "42") ==
             {:ok, %{nodes: [], cursor: "42", preferences: nil}}
  end

  test "pull/2 preserves returned preferences" do
    configure()
    project_id = Ecto.UUID.generate()

    preferences = %{
      "active_heads" => [Ecto.UUID.generate()],
      "session_pointer" => Ecto.UUID.generate(),
      "updated_at" => "2026-10-23T12:00:00.000000Z"
    }

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{nodes: [], cursor: "42", preferences: preferences})
    end)

    assert {:ok, %{nodes: [], cursor: "42", preferences: ^preferences}} =
             SyncClient.pull(project_id, "42")
  end

  test "push_preferences/1 posts flat versioned preferences" do
    configure()
    project_id = Ecto.UUID.generate()
    head = Ecto.UUID.generate()
    pointer = Ecto.UUID.generate()
    updated_at = "2026-10-23T12:00:00.000000Z"

    preferences = %PushPreferences{
      project_id: project_id,
      active_heads: [head],
      session_pointer: pointer,
      updated_at: updated_at
    }

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/sync/preferences"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{@token}"]

      assert conn.body_params == %{
               "project_id" => project_id,
               "active_heads" => [head],
               "session_pointer" => pointer,
               "updated_at" => updated_at
             }

      Req.Test.json(conn, %{preferences: conn.body_params})
    end)

    assert {:ok, %{preferences: %{"updated_at" => ^updated_at}}} =
             SyncClient.push_preferences(preferences)
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

  test "union/3 posts parents and returns the proposal reference" do
    configure()
    project_id = Ecto.UUID.generate()
    parents = [Ecto.UUID.generate(), Ecto.UUID.generate()]

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/sync/union"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{@token}"]
      assert conn.body_params == %{"project_id" => project_id, "parent_node_ids" => parents}

      Req.Test.json(conn, %{
        proposal_id: "p1",
        proposal_token: "tok",
        proposal_url: "https://cadence.example/proposals/tok",
        status: "pending",
        kind: "meld"
      })
    end)

    assert SyncClient.union(project_id, parents) ==
             {:ok,
              %{
                proposal_id: "p1",
                proposal_token: "tok",
                proposal_url: "https://cadence.example/proposals/tok",
                status: "pending",
                kind: "meld"
              }}
  end

  test "union/3 tolerates a server that omits proposal_url" do
    configure()
    parents = [Ecto.UUID.generate(), Ecto.UUID.generate()]

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        proposal_id: "p1",
        proposal_token: "tok",
        status: "pending",
        kind: "meld"
      })
    end)

    assert {:ok, %{proposal_url: nil}} = SyncClient.union(Ecto.UUID.generate(), parents)
  end

  test "union/3 rejects a malformed response and surfaces HTTP errors" do
    configure()
    parents = [Ecto.UUID.generate(), Ecto.UUID.generate()]

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{proposal_id: "p1"})
    end)

    assert SyncClient.union(Ecto.UUID.generate(), parents) ==
             {:error, {:invalid_response, %{"proposal_id" => "p1"}}}

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(403, Jason.encode!(%{error: "insufficient project role"}))
    end)

    assert SyncClient.union(Ecto.UUID.generate(), parents) ==
             {:error, {:http, 403, %{"error" => "insufficient project role"}}}
  end

  test "objects_exist/2 posts the batch and returns the present subset" do
    configure()
    project_id = Ecto.UUID.generate()
    shas = [String.duplicate("a", 40), String.duplicate("b", 40)]

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/sync/objects/exists"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{@token}"]
      assert conn.body_params == %{"project_id" => project_id, "shas" => shas}

      Req.Test.json(conn, %{present: [hd(shas)]})
    end)

    assert SyncClient.objects_exist(project_id, shas) == {:ok, [hd(shas)]}
  end

  test "objects_exist/2 rejects a malformed response" do
    configure()
    sha = String.duplicate("a", 40)

    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{present: [1]}) end)

    assert SyncClient.objects_exist(Ecto.UUID.generate(), [sha]) ==
             {:error, {:invalid_response, %{"present" => [1]}}}
  end

  defp configure do
    Application.put_env(:cadence_daemon, :server_url, "https://cadence.test")
    Application.put_env(:cadence_daemon, :auth_token, @token)
    Application.put_env(:cadence_daemon, :sync_req_options, plug: {Req.Test, __MODULE__})
  end
end
