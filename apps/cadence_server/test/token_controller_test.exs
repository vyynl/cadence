defmodule Cadence.ServerWeb.TokenControllerTest do
  use Cadence.ServerWeb.ConnCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Cadence.Server.Accounts.User
  alias Cadence.ServerWeb.TokenController

  setup do
    user = Ash.Seed.seed!(User, %{email: "tokens@example.com", name: "Token User"})
    {:ok, user: user}
  end

  test "GET /auth/tokens/new requires an OAuth session", %{conn: conn} do
    conn = get(conn, "/auth/tokens/new")

    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end

  test "GET /auth/tokens/new renders once signed in", %{conn: conn, user: user} do
    conn =
      conn
      |> assign(:current_user, user)
      |> TokenController.new(%{})

    assert conn.status == 200
    assert conn.resp_body =~ "Create a Cadence API key"
  end

  test "POST /auth/tokens issues a plaintext key once", %{conn: conn, user: user} do
    conn =
      conn
      |> assign(:current_user, user)
      |> TokenController.create(%{"name" => "daemon"})

    assert conn.status == 201
    assert conn.resp_body =~ "cad_"
    assert conn.resp_body =~ "CAD_AUTH_TOKEN"
  end
end
