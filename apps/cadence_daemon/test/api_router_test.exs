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
end
