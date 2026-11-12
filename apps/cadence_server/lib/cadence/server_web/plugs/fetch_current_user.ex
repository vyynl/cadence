defmodule Cadence.ServerWeb.Plugs.FetchCurrentUser do
  @moduledoc """
  Resolves the browser session into `:current_user` / `:current_session`.

  Reads the token from the Phoenix session, falling back to the signed
  remember-me cookie. A valid session older than the reissue window is rotated
  here; an expired/unknown one is cleared so a stale cookie cannot keep a page
  half-signed-in.
  """

  @behaviour Plug

  import Plug.Conn

  alias Cadence.ServerWeb.UserAuth

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = fetch_cookies(conn, signed: [UserAuth.remember_me_cookie()])
    {token, conn, from_cookie?} = token_from(conn)

    case token && UserAuth.verify_token(token) do
      {:ok, user, session} ->
        conn = if from_cookie?, do: put_session(conn, :user_remember_me, true), else: conn

        {token, session} =
          if UserAuth.needs_reissue?(session) do
            UserAuth.reissue(session)
          else
            {token, session}
          end

        conn =
          conn
          |> put_session(:user_session_token, token)
          |> put_session(:live_socket_id, UserAuth.session_topic(token))

        conn =
          if get_session(conn, :user_remember_me) == true do
            UserAuth.put_remember_me_cookie(conn, token)
          else
            conn
          end

        conn
        |> assign(:current_user, user)
        |> assign(:current_session, session)

      _other ->
        conn
        |> UserAuth.clear_session_state()
        |> assign(:current_user, nil)
        |> assign(:current_session, nil)
    end
  end

  defp token_from(conn) do
    case get_session(conn, :user_session_token) do
      token when is_binary(token) ->
        {token, conn, false}

      _other ->
        case conn.cookies[UserAuth.remember_me_cookie()] do
          token when is_binary(token) -> {token, conn, true}
          _other -> {nil, conn, false}
        end
    end
  end
end
