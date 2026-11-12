defmodule Cadence.ServerWeb.UserAuthTest do
  use Cadence.ServerWeb.ConnCase, async: false

  import Ecto.Query
  import Plug.Conn

  alias Cadence.Server.Accounts.LocalAuth
  alias Cadence.Server.Accounts.User
  alias Cadence.Server.Accounts.UserSession
  alias Cadence.Server.Repo
  alias Cadence.ServerWeb.UserAuth

  @cookie_user "session-user@example.com"

  setup %{conn: conn} do
    {:ok, user} =
      LocalAuth.create_user(%{email: @cookie_user, password: "correct horse battery staple"})

    conn =
      conn
      |> init_test_session(%{})
      |> Phoenix.Controller.fetch_flash()
      |> Map.put(:secret_key_base, Cadence.ServerWeb.Endpoint.config(:secret_key_base))

    {:ok, conn: conn, user: user}
  end

  test "log_in stores only a hash and rotates the session cookie", %{conn: conn, user: user} do
    conn = init_test_session(conn, %{stale: "value"})
    {conn, session} = UserAuth.log_in(conn, user)

    token = get_session(conn, :user_session_token)
    assert is_binary(token)
    assert session.token_hash == UserAuth.hash_token(token)
    refute session.token_hash == token
    refute get_session(conn, :stale)
    assert get_session(conn, :live_socket_id) == UserAuth.session_topic(token)
  end

  test "a signed-in conn sees its email on a page", %{conn: conn, user: user} do
    conn = init_test_session(conn, %{})
    {conn, _session} = UserAuth.log_in(conn, user)

    assert html_response(get(conn, "/"), 200) =~ to_string(user.email)
  end

  test "an anonymous conn sees no signed-in email", %{conn: conn} do
    refute html_response(get(conn, "/"), 200) =~ @cookie_user
  end

  test "logout revokes the row, clears the session, and broadcasts", %{conn: conn, user: user} do
    conn = init_test_session(conn, %{})
    {conn, _session} = UserAuth.log_in(conn, user)
    token = get_session(conn, :user_session_token)

    Phoenix.PubSub.subscribe(Cadence.Server.PubSub, UserAuth.session_topic(token))

    conn = UserAuth.log_out(conn)

    assert_receive %{"disconnect" => %{}}
    assert get_session(conn, :user_session_token) == nil
    refute Repo.get_by(UserSession, user_id: user.id)
    refute html_response(get(conn, "/"), 200) =~ to_string(user.email)
  end

  test "the remember-me cookie signs a new request in and is adopted", %{conn: conn, user: user} do
    conn = init_test_session(conn, %{})
    {conn, _session} = UserAuth.log_in(conn, user, remember_me: true)

    signed = conn.resp_cookies[UserAuth.remember_me_cookie()][:value]
    assert is_binary(signed)

    cookie_conn =
      build_conn()
      |> put_req_header("cookie", "#{UserAuth.remember_me_cookie()}=#{signed}")

    result = get(cookie_conn, "/")
    assert html_response(result, 200) =~ to_string(user.email)

    token = get_session(result, :user_session_token)
    assert is_binary(token)
    assert Repo.get_by(UserSession, token_hash: UserAuth.hash_token(token))
    assert Repo.aggregate(UserSession, :count) == 1
  end

  test "a session older than the reissue window is rotated in place", %{conn: conn, user: user} do
    conn = init_test_session(conn, %{})
    {conn, session} = UserAuth.log_in(conn, user)
    old_token = get_session(conn, :user_session_token)

    eight_days_ago = DateTime.add(DateTime.utc_now(), -8, :day)

    Repo.update_all(
      from(s in UserSession, where: s.id == ^session.id),
      set: [inserted_at: eight_days_ago]
    )

    result = get(conn, "/")
    assert html_response(result, 200) =~ to_string(user.email)

    new_token = get_session(result, :user_session_token)
    assert new_token != old_token
    refute Repo.get_by(UserSession, token_hash: UserAuth.hash_token(old_token))

    rotated = Repo.one(from(s in UserSession, where: s.user_id == ^user.id))
    assert rotated.authenticated_at == session.authenticated_at
  end

  test "an expired session is ignored", %{conn: conn, user: user} do
    conn = init_test_session(conn, %{})
    {conn, session} = UserAuth.log_in(conn, user)

    Repo.update_all(
      from(s in UserSession, where: s.id == ^session.id),
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -20, :day)]
    )

    refute html_response(get(conn, "/"), 200) =~ to_string(user.email)
  end

  test "revoke_all removes every session and broadcasts each", %{conn: conn, user: user} do
    conn = init_test_session(conn, %{})
    {conn, first} = UserAuth.log_in(conn, user)
    {_conn, second} = UserAuth.log_in(conn, user)

    Phoenix.PubSub.subscribe(
      Cadence.Server.PubSub,
      UserAuth.session_topic(get_session(conn, :user_session_token))
    )

    assert :ok = UserAuth.revoke_all(user.id)
    assert_receive %{"disconnect" => %{}}
    assert Repo.aggregate(from(s in UserSession, where: s.user_id == ^user.id), :count) == 0
    assert first.user_id == second.user_id
  end

  test "sudo mode tracks authenticated_at and is bounded by config" do
    fresh = %UserSession{authenticated_at: DateTime.utc_now()}
    stale = %UserSession{authenticated_at: DateTime.add(DateTime.utc_now(), -30, :minute)}

    assert UserAuth.sudo_mode?(fresh)
    refute UserAuth.sudo_mode?(stale)
    refute UserAuth.sudo_mode?(nil)

    original = Application.get_env(:cadence_server, :auth_sudo_minutes)
    Application.put_env(:cadence_server, :auth_sudo_minutes, 60)
    on_exit(fn -> Application.put_env(:cadence_server, :auth_sudo_minutes, original) end)

    assert UserAuth.sudo_mode?(stale)
  end

  test "a remember-me session reissues its cookie on rotation", %{conn: conn, user: user} do
    conn = init_test_session(conn, %{})
    {conn, session} = UserAuth.log_in(conn, user, remember_me: true)
    old_cookie = conn.resp_cookies[UserAuth.remember_me_cookie()][:value]

    Repo.update_all(
      from(s in UserSession, where: s.id == ^session.id),
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -8, :day)]
    )

    result = get(conn, "/")
    new_cookie = result.resp_cookies[UserAuth.remember_me_cookie()][:value]

    assert is_binary(new_cookie)
    assert new_cookie != old_cookie
    assert result.resp_cookies[UserAuth.remember_me_cookie()][:max_age] == 14 * 86_400
  end

  test "an unknown or malformed token is rejected" do
    assert UserAuth.verify_token("short") == :error
    assert UserAuth.verify_token(:crypto.strong_rand_bytes(32)) == :error
    assert UserAuth.verify_token(nil) == :error
  end

  test "the OAuth success callback creates a database session and honours return_to", %{
    conn: conn
  } do
    oauth_user = Ash.Seed.seed!(User, %{email: "oauth@example.com", name: "OAuth"})
    conn = init_test_session(conn, %{user_return_to: "/p/cadence-demo"})

    conn = Cadence.ServerWeb.AuthController.success(conn, :sign_in, oauth_user, "ignored-jwt")

    assert redirected_to(conn) == "/p/cadence-demo"
    assert is_binary(get_session(conn, :user_session_token))
    assert Repo.get_by(UserSession, user_id: oauth_user.id)
  end

  test "an unsafe OAuth return_to falls back to the portfolio", %{conn: conn} do
    oauth_user = Ash.Seed.seed!(User, %{email: "oauth-unsafe@example.com", name: "OAuth"})
    conn = init_test_session(conn, %{user_return_to: "//evil.example"})

    conn = Cadence.ServerWeb.AuthController.success(conn, :sign_in, oauth_user, "ignored-jwt")

    assert redirected_to(conn) == "/"
  end

  test "POST /sign-out clears the session and keeps the flash through the pipeline", %{
    conn: conn,
    user: user
  } do
    conn = init_test_session(conn, %{})
    {conn, _session} = UserAuth.log_in(conn, user)

    conn = post(conn, "/sign-out")

    assert redirected_to(conn) == "/"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Signed out."
    refute Repo.get_by(UserSession, user_id: user.id)
  end
end
