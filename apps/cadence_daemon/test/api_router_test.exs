defmodule Cadence.Daemon.API.RouterTest do
  use ExUnit.Case, async: false

  alias Cadence.Daemon.API.Router
  alias Cadence.Daemon.Repo
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

  test "GET /nodes returns 404 for an unknown project" do
    conn = Plug.Test.conn(:get, "/nodes?project_id=#{Ecto.UUID.generate()}") |> call()
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
