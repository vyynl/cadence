defmodule Cadence.Daemon.API.RouterTest do
  use ExUnit.Case, async: false

  alias Cadence.Daemon.API.Router
  alias Cadence.Daemon.{ProjectLocation, Repo, SyncLedger}
  alias Cadence.Shared.{Node, Project}

  defp call(conn), do: Router.call(conn, [])

  test "GET /health" do
    conn = Plug.Test.conn(:get, "/health") |> call()
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["status"] == "ok"
  end

  test "GET /projects returns a list" do
    conn = Plug.Test.conn(:get, "/projects") |> call()
    assert conn.status == 200
    assert is_list(Jason.decode!(conn.resp_body)["projects"])
  end

  test "POST /projects with an invalid slug returns 422" do
    conn =
      Plug.Test.conn(
        :post,
        "/projects",
        Jason.encode!(%{
          "name" => "x",
          "slug" => "NOT_VALID",
          "work_dir" => "/tmp/x"
        })
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> call()

    assert conn.status == 422
  end

  test "POST /projects missing work_dir returns 422" do
    conn =
      Plug.Test.conn(:post, "/projects", Jason.encode!(%{"name" => "x", "slug" => "x-1"}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> call()

    assert conn.status == 422
  end

  test "GET /nodes requires project_id" do
    conn = Plug.Test.conn(:get, "/nodes") |> call()
    assert conn.status == 400
  end

  test "GET /nodes orders deterministically when timestamps tie" do
    owner_id = Ecto.UUID.generate()

    {:ok, project} =
      %{name: "n", slug: "nodes-#{System.unique_integer([:positive])}", owner_id: owner_id}
      |> Project.changeset()
      |> Repo.insert()

    created_at = ~U[2026-10-14 12:00:00.000000Z]
    [high_id, low_id] = Enum.sort([Ecto.UUID.generate(), Ecto.UUID.generate()], :desc)

    Enum.each([low_id, high_id], fn id ->
      %{
        id: id,
        project_id: project.id,
        git_commit_sha: String.duplicate("c", 40),
        flags: [:"in-progress"],
        message: "m",
        created_by: owner_id,
        created_at: created_at,
        docs_state: :pending
      }
      |> Node.changeset()
      |> Repo.insert!()
    end)

    conn = Plug.Test.conn(:get, "/nodes?project_id=#{project.id}") |> call()
    assert conn.status == 200

    assert Enum.map(Jason.decode!(conn.resp_body)["nodes"], & &1["id"]) == [high_id, low_id]
  end

  test "POST /union validates its payload and resolves the local project" do
    assert post_json("/union", %{}).status == 422
    assert post_json("/union", %{"project_id" => nil, "parent_node_ids" => []}).status == 422

    nine = Enum.map(1..9, fn _ -> Ecto.UUID.generate() end)

    assert post_json("/union", %{
             "project_id" => Ecto.UUID.generate(),
             "parent_node_ids" => nine
           }).status == 422

    assert post_json("/union", %{
             "project_id" => Ecto.UUID.generate(),
             "parent_node_ids" => [Ecto.UUID.generate()]
           }).status == 422

    assert post_json("/union", %{
             "project_id" => Ecto.UUID.generate(),
             "parent_node_ids" => [Ecto.UUID.generate(), Ecto.UUID.generate()]
           }).status == 404
  end

  test "POST /union returns 503 when sync is not configured" do
    project = insert_local_project()

    conn =
      post_json("/union", %{
        "project_id" => project.id,
        "parent_node_ids" => [Ecto.UUID.generate(), Ecto.UUID.generate()]
      })

    assert conn.status == 503
    assert Jason.decode!(conn.resp_body)["error"] == "sync is not configured"
  end

  test "POST /union returns the proposal token and URL" do
    project = insert_local_project()
    configure_sync!(project)
    Req.Test.verify_on_exit!()

    parent_ids = [Ecto.UUID.generate(), Ecto.UUID.generate()]

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/sync/union"
      assert conn.body_params["project_id"] == project.id
      assert conn.body_params["parent_node_ids"] == parent_ids

      Req.Test.json(conn, %{
        proposal_id: "p1",
        proposal_token: "tok",
        status: "pending",
        kind: "meld"
      })
    end)

    conn =
      post_json("/union", %{"project_id" => project.id, "parent_node_ids" => parent_ids})

    assert conn.status == 201
    body = Jason.decode!(conn.resp_body)
    assert body["proposal_id"] == "p1"
    assert body["proposal_token"] == "tok"
    assert body["proposal_url"] == "http://server.test/proposals/tok"
    assert body["status"] == "pending"
  end

  test "POST /union passes through server statuses and improves actionable errors" do
    project = insert_local_project()
    configure_sync!(project)
    parent_ids = [Ecto.UUID.generate(), Ecto.UUID.generate()]
    payload = %{"project_id" => project.id, "parent_node_ids" => parent_ids}

    for {status, server_body, expected} <- [
          {403, %{"error" => "insufficient project role"}, "insufficient project role"},
          {500, %{"error" => "sync failed"}, "sync failed"},
          {502, %{"error" => "meld failed"}, "meld failed"},
          {422, %{"error" => "invalid parent"}, "one or more selected nodes are not synced yet"},
          {429, %{"error" => "meld rate limited"}, "meld rate limited; retry shortly"}
        ] do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, Jason.encode!(server_body))
      end)

      conn = post_json("/union", payload)
      assert conn.status == status
      assert Jason.decode!(conn.resp_body)["error"] == expected
    end
  end

  test "POST /union maps transport failures to 503 and 504" do
    project = insert_local_project()
    configure_sync!(project)

    payload = %{
      "project_id" => project.id,
      "parent_node_ids" => [Ecto.UUID.generate(), Ecto.UUID.generate()]
    }

    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
    conn = post_json("/union", payload)
    assert conn.status == 503
    assert Jason.decode!(conn.resp_body)["error"] == "sync server unreachable"

    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)
    conn = post_json("/union", payload)
    assert conn.status == 504
    assert Jason.decode!(conn.resp_body)["error"] == "sync timed out"
  end

  test "POST /spawn for an unknown project returns 404" do
    conn =
      Plug.Test.conn(:post, "/spawn", Jason.encode!(%{"project_id" => Ecto.UUID.generate()}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> call()

    assert conn.status == 404
  end

  test "POST /switch for an unknown project returns 404" do
    conn =
      Plug.Test.conn(
        :post,
        "/switch",
        Jason.encode!(%{
          "project_id" => Ecto.UUID.generate(),
          "node_id" => Ecto.UUID.generate()
        })
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> call()

    assert conn.status == 404
  end

  test "POST /switch rejects a malformed node_id" do
    project = insert_project(Ecto.UUID.generate())

    conn =
      Plug.Test.conn(
        :post,
        "/switch",
        Jason.encode!(%{"project_id" => project.id, "node_id" => "not-a-uuid"})
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> call()

    assert conn.status == 404
  end

  test "GET /nodes returns 404 for an unknown project" do
    conn = Plug.Test.conn(:get, "/nodes?project_id=#{Ecto.UUID.generate()}") |> call()
    assert conn.status == 404
  end

  test "GET /nodes returns 404 for a malformed project_id" do
    conn = Plug.Test.conn(:get, "/nodes?project_id=not-a-uuid") |> call()
    assert conn.status == 404
  end

  test "GET /graph requires project_id" do
    conn = Plug.Test.conn(:get, "/graph") |> call()
    assert conn.status == 400
  end

  test "GET /graph returns 404 for an unknown project" do
    conn = Plug.Test.conn(:get, "/graph?project_id=#{Ecto.UUID.generate()}") |> call()
    assert conn.status == 404
  end

  test "GET /graph returns structural depth, edges, and session" do
    project = insert_project(Ecto.UUID.generate())
    root_id = Ecto.UUID.generate()
    child_id = Ecto.UUID.generate()

    insert_node(project.id, root_id, [], ~U[2026-10-14 10:00:00.000000Z])
    insert_node(project.id, child_id, [root_id], ~U[2026-10-14 11:00:00.000000Z])

    conn = Plug.Test.conn(:get, "/graph?project_id=#{project.id}") |> call()
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    assert body["project_id"] == project.id
    assert body["session"]["user_id"] == Application.get_env(:cadence_daemon, :local_user_id)
    assert body["session"]["session_pointer"] == nil
    assert body["edges"] == [%{"from" => root_id, "to" => child_id}]

    depths = Map.new(body["nodes"], &{&1["id"], &1["depth"]})
    assert depths[root_id] == 0
    assert depths[child_id] == 1

    # No pointer, and the local user created both nodes → newest by that user.
    assert body["default_node_id"] == child_id
    assert body["preview_node_id"] == child_id
  end

  test "GET /diff requires project_id and node_id" do
    conn = Plug.Test.conn(:get, "/diff?project_id=#{Ecto.UUID.generate()}") |> call()
    assert conn.status == 400

    conn = Plug.Test.conn(:get, "/diff") |> call()
    assert conn.status == 400
  end

  test "GET /diff returns 404 for an unknown project" do
    conn =
      Plug.Test.conn(
        :get,
        "/diff?project_id=#{Ecto.UUID.generate()}&node_id=#{Ecto.UUID.generate()}"
      )
      |> call()

    assert conn.status == 404
  end

  test "GET /diff returns 404 for a node not in the project" do
    project = insert_project(Ecto.UUID.generate())

    conn =
      Plug.Test.conn(
        :get,
        "/diff?project_id=#{project.id}&node_id=#{Ecto.UUID.generate()}"
      )
      |> call()

    assert conn.status == 404
  end

  test "GET /diff returns 404 for a malformed node_id" do
    project = insert_project(Ecto.UUID.generate())

    conn =
      Plug.Test.conn(
        :get,
        "/diff?project_id=#{project.id}&node_id=not-a-uuid"
      )
      |> call()

    assert conn.status == 404
  end

  defp configure_sync!(project) do
    {:ok, _user_id} = SyncLedger.put_server_user_id(Ecto.UUID.generate())
    :ok = SyncLedger.mark_provisioned(project.id)

    Application.put_env(:cadence_daemon, :server_url, "http://server.test")
    Application.put_env(:cadence_daemon, :auth_token, "test-token")
    Application.put_env(:cadence_daemon, :sync_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.delete_env(:cadence_daemon, :server_url)
      Application.delete_env(:cadence_daemon, :auth_token)
      Application.delete_env(:cadence_daemon, :sync_req_options)
    end)
  end

  defp post_json(path, body) do
    Plug.Test.conn(:post, path, Jason.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> call()
  end

  defp insert_local_project do
    dir =
      Path.join(System.tmp_dir!(), "cadence_api_union_#{System.unique_integer([:positive])}")

    work_dir = Path.join(dir, "work")
    File.mkdir_p!(work_dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    project =
      %{
        name: "u",
        slug: "u-#{System.unique_integer([:positive])}",
        owner_id: Ecto.UUID.generate()
      }
      |> Project.changeset()
      |> Repo.insert!()

    %ProjectLocation{}
    |> ProjectLocation.changeset(%{
      project_id: project.id,
      work_dir: work_dir,
      git_dir: Path.join(dir, "git"),
      created_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    project
  end

  defp insert_project(owner_id) do
    %{name: "g", slug: "g-#{System.unique_integer([:positive])}", owner_id: owner_id}
    |> Project.changeset()
    |> Repo.insert!()
  end

  defp insert_node(project_id, id, parents, created_at) do
    %{
      id: id,
      project_id: project_id,
      git_commit_sha: String.duplicate("d", 40),
      parents: parents,
      flags: [:"in-progress"],
      message: "m",
      created_by: Application.get_env(:cadence_daemon, :local_user_id),
      created_at: created_at,
      docs_state: :pending
    }
    |> Node.changeset()
    |> Repo.insert!()
  end
end
