defmodule Cadence.ServerWeb.TokenControllerTest do
  use Cadence.ServerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.ConnTest
  import Plug.Conn

  alias Cadence.Server.Accounts.ApiKey
  alias Cadence.Server.Accounts.User
  alias Cadence.Server.Accounts.UserSession
  alias Cadence.Server.Repo
  alias Cadence.ServerWeb.TokenController

  setup do
    user = Ash.Seed.seed!(User, %{email: "tokens@example.com", name: "Token User"})
    {:ok, user: user}
  end

  test "GET /auth/tokens/new requires an OAuth session", %{conn: conn} do
    conn = get(conn, "/auth/tokens/new")

    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end

  test "GET /auth/tokens/new renders inside the sudo window", %{conn: conn, user: user} do
    conn =
      conn
      |> init_test_session(%{})
      |> assign(:current_user, user)
      |> assign(:current_session, session_at(0))
      |> TokenController.new(%{})

    assert conn.status == 200
    assert conn.resp_body =~ "Create a daemon token"
  end

  test "POST /auth/tokens issues a plaintext key once", %{conn: conn, user: user} do
    conn =
      conn
      |> init_test_session(%{})
      |> assign(:current_user, user)
      |> assign(:current_session, session_at(0))
      |> TokenController.create(%{"name" => "daemon"})

    assert conn.status == 201
    assert conn.resp_body =~ "cad_"
    assert conn.resp_body =~ "CAD_AUTH_TOKEN"
  end

  test "GET /auth/tokens/new sends a stale session through re-authentication", %{
    conn: conn,
    user: user
  } do
    conn =
      conn
      |> init_test_session(%{})
      |> Phoenix.Controller.fetch_flash()
      |> assign(:current_user, user)
      |> assign(:current_session, session_at(30))
      |> TokenController.new(%{})

    assert conn.halted
    assert redirected_to(conn) == "/sign-in?sudo=1&return_to=/auth/tokens/new"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             "Re-authenticate to create a daemon token."
  end

  test "POST /auth/tokens mints nothing outside the sudo window", %{conn: conn, user: user} do
    conn =
      conn
      |> init_test_session(%{})
      |> Phoenix.Controller.fetch_flash()
      |> assign(:current_user, user)
      |> assign(:current_session, session_at(30))
      |> TokenController.create(%{"name" => "daemon"})

    assert conn.halted
    assert redirected_to(conn) == "/sign-in?sudo=1&return_to=/auth/tokens/new"
    assert api_key_count(user) == 0
  end

  test "the router refuses a session older than the sudo window", %{conn: conn, user: user} do
    conn = signed_conn(conn, user)

    Repo.update_all(
      from(s in UserSession, where: s.user_id == ^user.id),
      set: [authenticated_at: DateTime.add(DateTime.utc_now(), -30, :minute)]
    )

    conn = get(conn, "/auth/tokens/new")

    assert redirected_to(conn) == "/sign-in?sudo=1&return_to=/auth/tokens/new"
    assert api_key_count(user) == 0
  end

  defp session_at(minutes_ago) do
    %UserSession{authenticated_at: DateTime.add(DateTime.utc_now(), -minutes_ago, :minute)}
  end

  defp api_key_count(user) do
    Repo.aggregate(from(k in ApiKey, where: k.user_id == ^user.id), :count)
  end

  defp signed_conn(conn, user) do
    conn = init_test_session(conn, %{})
    {conn, _session} = Cadence.ServerWeb.UserAuth.log_in(conn, user)
    conn
  end
end
