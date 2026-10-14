defmodule Cadence.Daemon.API.RouterTest do
  use ExUnit.Case, async: false

  alias Cadence.Daemon.API.Router

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
