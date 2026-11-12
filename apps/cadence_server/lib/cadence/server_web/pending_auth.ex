defmodule Cadence.ServerWeb.PendingAuth do
  @moduledoc """
  The short-lived second-factor hand-off.

  A correct password does not create a session until TOTP is verified or
  enrolled. Until then only these signed-session keys exist: the user id, the
  start time (5-minute TTL), and the remember-me choice. There is no
  half-authenticated application session.
  """

  alias Cadence.Server.Accounts
  alias Cadence.Server.Accounts.User

  @ttl_seconds 300

  @doc "Stores the pending second-factor hand-off for a user."
  @spec put(Plug.Conn.t(), User.t(), keyword()) :: Plug.Conn.t()
  def put(conn, %User{id: id}, opts \\ []) do
    conn
    |> Plug.Conn.put_session(:totp_pending_user_id, id)
    |> Plug.Conn.put_session(:totp_pending_at, System.system_time(:second))
    |> Plug.Conn.put_session(:totp_pending_remember_me, Keyword.get(opts, :remember_me, false))
  end

  @doc "Returns the pending user if the hand-off is still valid."
  @spec fetch(Plug.Conn.t()) :: {:ok, User.t()} | :error
  def fetch(conn) do
    with id when is_binary(id) <- Plug.Conn.get_session(conn, :totp_pending_user_id),
         started_at when is_integer(started_at) <- Plug.Conn.get_session(conn, :totp_pending_at),
         true <- System.system_time(:second) - started_at <= @ttl_seconds,
         {:ok, %User{} = user} <- Ash.get(User, id, domain: Accounts) do
      {:ok, user}
    else
      _other -> :error
    end
  end

  @doc "The remember-me choice made on the password form."
  @spec remember_me?(Plug.Conn.t()) :: boolean()
  def remember_me?(conn) do
    Plug.Conn.get_session(conn, :totp_pending_remember_me) == true
  end

  @doc "Clears the pending hand-off."
  @spec clear(Plug.Conn.t()) :: Plug.Conn.t()
  def clear(conn) do
    conn
    |> Plug.Conn.delete_session(:totp_pending_user_id)
    |> Plug.Conn.delete_session(:totp_pending_at)
    |> Plug.Conn.delete_session(:totp_pending_remember_me)
  end
end
