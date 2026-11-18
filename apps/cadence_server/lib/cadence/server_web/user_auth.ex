defmodule Cadence.ServerWeb.UserAuth do
  @moduledoc """
  Browser session lifecycle, remember-me, sudo mode, and LiveView auth hooks
  (spec §7.4).

  Sessions are database rows (`user_sessions`) holding only a SHA-256 hash of
  the random token. The token itself lives in the signed Phoenix session and,
  when requested, in a signed remember-me cookie. Logout deletes the row and
  broadcasts a disconnect on the session's topic so open LiveViews drop.

  LiveViews get `:current_user` and `:current_session` from
  `on_mount(:mount_current_user)`; `:require_authenticated_user`,
  `:require_totp_enrolled`, and `:require_sudo_mode` add gates. Every
  `handle_event` that touches data still re-checks membership/roles.
  """

  import Ecto.Query
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, put_flash: 3, redirect: 2]

  alias Cadence.Server.Accounts.TOTP
  alias Cadence.Server.Accounts.User
  alias Cadence.Server.Accounts.UserSession
  alias Cadence.Server.Repo
  alias Cadence.ServerWeb.SessionOptions

  @remember_me_cookie "_cadence_remember_me"
  @token_bytes 32

  @doc "The signed remember-me cookie name."
  @spec remember_me_cookie() :: String.t()
  def remember_me_cookie, do: @remember_me_cookie

  @doc """
  Logs a user in and rotates the session identifier.

  The caller is responsible for redirecting and for setting any flash after
  this returns: the pre-authentication session is cleared here to prevent
  fixation.
  """
  @spec log_in(Plug.Conn.t(), User.t(), keyword()) :: {Plug.Conn.t(), UserSession.t()}
  def log_in(%Plug.Conn{} = conn, %User{} = user, opts \\ []) do
    token = generate_token()
    session = insert_session!(user.id, token, now_seconds())
    return_to = Plug.Conn.get_session(conn, :user_return_to)

    conn =
      conn
      |> Plug.Conn.configure_session(renew: true)
      |> Plug.Conn.clear_session()
      |> Plug.Conn.put_session(:user_session_token, token)
      |> Plug.Conn.put_session(:live_socket_id, session_topic(token))
      |> restore_return_to(return_to)
      |> Plug.Conn.delete_session(:totp_pending_user_id)
      |> Plug.Conn.delete_session(:totp_pending_at)
      |> Plug.Conn.delete_session(:totp_pending_remember_me)
      |> maybe_write_remember_me(token, Keyword.get(opts, :remember_me, false))

    {conn, session}
  end

  @doc """
  Logs a user in, sets a flash, and redirects to the validated return path.

  Intended for controllers: it captures `user_return_to` before `log_in/3`
  clears the pre-authentication session.
  """
  @spec log_in_and_redirect(Plug.Conn.t(), User.t(), keyword()) :: Plug.Conn.t()
  def log_in_and_redirect(%Plug.Conn{} = conn, %User{} = user, opts \\ []) do
    return_to = Cadence.ServerWeb.ReturnTo.safe(Plug.Conn.get_session(conn, :user_return_to))
    {conn, _session} = log_in(conn, user, Keyword.take(opts, [:remember_me]))

    conn
    |> Phoenix.Controller.put_flash(:info, Keyword.get(opts, :flash, "Signed in."))
    |> Phoenix.Controller.redirect(to: return_to)
  end

  @doc """
  Logs out the current session: deletes the row, disconnects its LiveViews,
  clears the session, and expires the remember-me cookie.
  """
  @spec log_out(Plug.Conn.t()) :: Plug.Conn.t()
  def log_out(%Plug.Conn{} = conn) do
    token =
      Plug.Conn.get_session(conn, :user_session_token) ||
        conn.cookies[@remember_me_cookie]

    revoke(token)

    conn
    |> Plug.Conn.configure_session(renew: true)
    |> Plug.Conn.clear_session()
    |> Plug.Conn.delete_resp_cookie(@remember_me_cookie, remember_me_cookie_options(conn))
  end

  @doc "Revokes one session by its raw token (idempotent)."
  @spec revoke(term()) :: :ok
  def revoke(token) when is_binary(token) and byte_size(token) > 0 do
    case Repo.get_by(UserSession, token_hash: hash_token(token)) do
      nil ->
        :ok

      session ->
        Repo.delete!(session)
        broadcast_disconnect(session.token_hash)
        :ok
    end
  end

  def revoke(_token), do: :ok

  @doc """
  Revokes every session for a user (password change, TOTP reset, operator
  reset) and disconnects their LiveViews.
  """
  @spec revoke_all(Ecto.UUID.t()) :: :ok
  def revoke_all(user_id) do
    sessions = Repo.all(from(s in UserSession, where: s.user_id == ^user_id))
    Repo.delete_all(from(s in UserSession, where: s.user_id == ^user_id))
    Enum.each(sessions, &broadcast_disconnect(&1.token_hash))
    :ok
  end

  @doc """
  Revokes every session for a user except the current one.

  Used after a successful password change (the acting session stays valid; it
  was just re-authenticated) and by "sign out other sessions".
  """
  @spec revoke_all_except(Ecto.UUID.t(), term()) :: :ok
  def revoke_all_except(user_id, current_session_id) do
    sessions =
      Repo.all(
        from(s in UserSession,
          where: s.user_id == ^user_id and s.id != ^current_session_id
        )
      )

    Repo.delete_all(
      from(s in UserSession,
        where: s.user_id == ^user_id and s.id != ^current_session_id
      )
    )

    Enum.each(sessions, &broadcast_disconnect(&1.token_hash))
    :ok
  end

  @doc """
  Resolves a session token to `{:ok, user, session}`. Expired or unknown
  tokens are `:error`.
  """
  @spec verify_token(term()) :: {:ok, User.t(), UserSession.t()} | :error
  def verify_token(token) when is_binary(token) and byte_size(token) >= 16 do
    cutoff = DateTime.add(DateTime.utc_now(), -ttl_days() * 86_400, :second)

    query =
      from(s in UserSession,
        join: u in User,
        on: u.id == s.user_id,
        where: s.token_hash == ^hash_token(token) and s.inserted_at > ^cutoff,
        select: {s, u}
      )

    case Repo.one(query) do
      {session, user} -> {:ok, user, session}
      nil -> :error
    end
  end

  def verify_token(_token), do: :error

  @doc "Whether a session is old enough for its token to be rotated."
  @spec needs_reissue?(UserSession.t()) :: boolean()
  def needs_reissue?(%UserSession{inserted_at: inserted_at}) do
    DateTime.diff(DateTime.utc_now(), inserted_at, :day) >= reissue_days()
  end

  @doc """
  Rotates a session token while preserving `authenticated_at` (rotation is not
  a fresh authentication and must not extend the sudo window).
  """
  @spec reissue(UserSession.t()) :: {String.t(), UserSession.t()}
  def reissue(%UserSession{} = session) do
    token = generate_token()

    new_session =
      build_session(session.user_id, token, session.authenticated_at, DateTime.utc_now())

    Repo.transaction(fn ->
      Repo.insert!(new_session)
      Repo.delete_all(from(s in UserSession, where: s.id == ^session.id))
    end)

    {token, new_session}
  end

  @doc "Writes the signed remember-me cookie for a token."
  @spec put_remember_me_cookie(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def put_remember_me_cookie(conn, token) do
    Plug.Conn.put_resp_cookie(conn, @remember_me_cookie, token, remember_me_cookie_options(conn))
  end

  @doc "Removes the remember-me cookie."
  @spec delete_remember_me_cookie(Plug.Conn.t()) :: Plug.Conn.t()
  def delete_remember_me_cookie(conn) do
    Plug.Conn.delete_resp_cookie(conn, @remember_me_cookie, remember_me_cookie_options(conn))
  end

  @doc "Clears only the session-token state (pending TOTP keys survive)."
  @spec clear_session_state(Plug.Conn.t()) :: Plug.Conn.t()
  def clear_session_state(conn) do
    conn =
      conn
      |> Plug.Conn.delete_session(:user_session_token)
      |> Plug.Conn.delete_session(:live_socket_id)
      |> Plug.Conn.delete_session(:user_remember_me)

    if conn.cookies[@remember_me_cookie] do
      delete_remember_me_cookie(conn)
    else
      conn
    end
  end

  @doc "Whether the session authenticated within the sudo window."
  @spec sudo_mode?(UserSession.t() | nil) :: boolean()
  def sudo_mode?(%UserSession{authenticated_at: %DateTime{} = at}) do
    DateTime.diff(DateTime.utc_now(), at, :second) <= sudo_minutes() * 60
  end

  def sudo_mode?(_session), do: false

  @doc "The PubSub topic used to disconnect one session's LiveViews."
  @spec session_topic(String.t()) :: String.t()
  def session_topic(token), do: topic_from_hash(hash_token(token))

  @doc "SHA-256 of a session token (the value stored in the database)."
  @spec hash_token(String.t()) :: binary()
  def hash_token(token), do: :crypto.hash(:sha256, token)

  ## LiveView lifecycle

  @doc false
  def on_mount(:mount_current_user, _params, session, socket) do
    {user, user_session, token} = load_session_map(session)
    {:cont, finish_mount(socket, user, user_session, token)}
  end

  def on_mount(:require_authenticated_user, _params, session, socket) do
    case load_session_map(session) do
      {nil, _session, _token} ->
        {:halt,
         socket
         |> put_flash(:error, "You must sign in to access this page.")
         |> redirect(to: "/sign-in")}

      {user, user_session, token} ->
        {:cont, finish_mount(socket, user, user_session, token)}
    end
  end

  def on_mount(:require_totp_enrolled, _params, session, socket) do
    case load_session_map(session) do
      {nil, _session, _token} ->
        {:halt,
         socket
         |> put_flash(:error, "You must sign in to access this page.")
         |> redirect(to: "/sign-in")}

      {%User{} = user, user_session, token} ->
        if TOTP.enabled?(user) or is_nil(user.hashed_password) or not totp_required?() do
          {:cont, finish_mount(socket, user, user_session, token)}
        else
          {:halt,
           socket
           |> put_flash(:error, "Set up two-factor authentication to continue.")
           |> redirect(to: "/sign-in")}
        end
    end
  end

  def on_mount(:require_sudo_mode, _params, session, socket) do
    case load_session_map(session) do
      {nil, _session, _token} ->
        {:halt,
         socket
         |> put_flash(:error, "You must sign in to access this page.")
         |> redirect(to: "/sign-in")}

      {user, user_session, token} ->
        if sudo_mode?(user_session) do
          {:cont, finish_mount(socket, user, user_session, token)}
        else
          {:halt,
           socket
           |> put_flash(:error, "Re-authenticate to continue.")
           |> redirect(to: "/sign-in?sudo=1&return_to=/account")}
        end
    end
  end

  ## Helpers

  defp load_session_map(session) do
    with token when is_binary(token) <- session["user_session_token"],
         {:ok, user, user_session} <- verify_token(token) do
      {user, user_session, token}
    else
      _other -> {nil, nil, nil}
    end
  end

  defp finish_mount(socket, user, user_session, token) do
    socket
    |> Phoenix.Component.assign(:current_user, user)
    |> Phoenix.Component.assign(:current_session, user_session)
    |> subscribe_to_session(token)
  end

  defp subscribe_to_session(socket, token) when is_binary(token) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Cadence.Server.PubSub, session_topic(token))

      attach_hook(socket, :session_disconnect, :handle_info, fn
        %{"disconnect" => _payload}, socket ->
          {:halt, redirect(socket, to: "/sign-in")}

        _message, socket ->
          {:cont, socket}
      end)
    else
      socket
    end
  end

  defp subscribe_to_session(socket, _token), do: socket

  defp restore_return_to(conn, return_to) when is_binary(return_to) do
    Plug.Conn.put_session(conn, :user_return_to, return_to)
  end

  defp restore_return_to(conn, _return_to), do: conn

  defp maybe_write_remember_me(conn, token, true) do
    conn
    |> Plug.Conn.put_session(:user_remember_me, true)
    |> put_remember_me_cookie(token)
  end

  defp maybe_write_remember_me(conn, _token, _remember_me) do
    conn
    |> Plug.Conn.delete_session(:user_remember_me)
    |> delete_remember_me_cookie()
  end

  defp insert_session!(user_id, token, authenticated_at) do
    session = build_session(user_id, token, authenticated_at, DateTime.utc_now())
    Repo.insert!(session)
  end

  defp build_session(user_id, token, authenticated_at, inserted_at) do
    %UserSession{
      id: Ecto.UUID.generate(),
      user_id: user_id,
      token_hash: hash_token(token),
      authenticated_at: authenticated_at,
      inserted_at: inserted_at
    }
  end

  defp generate_token, do: :crypto.strong_rand_bytes(@token_bytes)

  defp now_seconds, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp topic_from_hash(token_hash) do
    "users_sessions:" <> Base.url_encode64(token_hash, padding: false)
  end

  defp broadcast_disconnect(token_hash) do
    Phoenix.PubSub.broadcast(
      Cadence.Server.PubSub,
      topic_from_hash(token_hash),
      %{"disconnect" => %{}}
    )
  rescue
    # A shell task may run without the PubSub tree (or it may be shutting
    # down); the session row is already gone, so the broadcast is best-effort.
    _error -> :ok
  end

  # Same host rule as the session cookie: remember-me on a private address
  # must not be born `Secure` (spec §12.9).
  defp remember_me_cookie_options(conn) do
    [
      sign: true,
      max_age: ttl_days() * 86_400,
      same_site: "Lax",
      http_only: true,
      secure: SessionOptions.secure?(conn.host)
    ]
  end

  defp ttl_days, do: int_config(:session_ttl_days, 14)
  defp reissue_days, do: int_config(:session_reissue_days, 7)
  defp sudo_minutes, do: int_config(:auth_sudo_minutes, 20)

  defp totp_required? do
    Application.get_env(:cadence_server, :auth_totp_required, true) == true
  end

  defp int_config(key, default) do
    case Application.get_env(:cadence_server, key, default) do
      value when is_integer(value) and value > 0 -> value
      _other -> default
    end
  end
end
