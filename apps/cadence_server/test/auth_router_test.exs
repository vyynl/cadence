defmodule Cadence.ServerWeb.AuthRouterTest do
  use Cadence.ServerWeb.ConnCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Cadence.Server.Accounts
  alias Cadence.Server.Accounts.User

  setup do
    user = Ash.Seed.seed!(User, %{email: "router@example.com", name: "Router"})
    assert {:ok, api_key} = Accounts.create_api_key(user, "test")

    %{
      user: user,
      api_key: api_key,
      plaintext: api_key.__metadata__.plaintext_api_key
    }
  end

  test "GET /health is public", %{conn: conn} do
    conn = get(conn, "/health")

    assert json_response(conn, 200) == %{"status" => "ok"}
  end

  test "GET /sync/me rejects a missing key", %{conn: conn} do
    conn = get(conn, "/sync/me")

    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end

  test "GET /sync/me rejects a malformed key", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer cad_bogus")
      |> get("/sync/me")

    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end

  test "GET /sync/me rejects a revoked key", %{
    conn: conn,
    api_key: api_key,
    plaintext: plaintext
  } do
    assert :ok = Ash.destroy(api_key)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{plaintext}")
      |> get("/sync/me")

    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end

  test "GET /sync/me accepts a valid key", %{
    conn: conn,
    user: user,
    plaintext: plaintext
  } do
    conn =
      conn
      |> put_req_header("authorization", "Bearer #{plaintext}")
      |> put_req_header("accept", "application/json")
      |> get("/sync/me")

    assert json_response(conn, 200) == %{
             "user_id" => user.id,
             "email" => "router@example.com",
             "name" => "Router"
           }
  end
end
