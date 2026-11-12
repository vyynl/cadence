defmodule Cadence.ServerWeb.PasskeyHelpers do
  @moduledoc """
  Shared guards for the passkey controllers (plan §7.5–§7.8).

  Every action re-reads `conn.assigns[:current_user]`; nothing here trusts an
  earlier action or a plug to have authorized the request. `with_user/2` and
  `with_enabled/2` run the action callback only after the guards pass and
  always return a `Plug.Conn`, never an internal tuple:

      PasskeyHelpers.with_user(conn, fn conn, user ->
        ...
      end)

  When `CAD_WEBAUTHN_ENABLED=false` the routes still exist but answer `404`;
  the header link and sign-in CTA are hidden by the layout/view.
  """

  import Phoenix.Controller
  import Plug.Conn

  alias Cadence.Server.Accounts.User
  alias Cadence.Server.Passkeys.Config
  alias Cadence.ServerWeb.JSON

  @doc "Halts with a `404` page when passkeys are disabled."
  @spec ensure_enabled(Plug.Conn.t()) :: {:ok, Plug.Conn.t()} | {:halt, Plug.Conn.t()}
  def ensure_enabled(conn) do
    if Config.enabled?(), do: {:ok, conn}, else: {:halt, not_found(conn)}
  end

  @doc "Re-reads `current_user` and halts when the request is anonymous."
  @spec require_user(Plug.Conn.t()) :: {:ok, User.t()} | {:halt, Plug.Conn.t()}
  def require_user(conn) do
    case conn.assigns[:current_user] do
      %User{} = user -> {:ok, user}
      _other -> {:halt, unauthenticated(conn)}
    end
  end

  @doc """
  Runs `fun` only when passkeys are enabled and the request is authenticated.

  Returns the conn in every case, including the halted guard responses, so a
  controller action never leaks an internal tuple to the Phoenix plug stack.
  """
  @spec with_user(Plug.Conn.t(), (Plug.Conn.t(), User.t() -> Plug.Conn.t())) :: Plug.Conn.t()
  def with_user(conn, fun) do
    with {:ok, conn} <- ensure_enabled(conn),
         {:ok, user} <- require_user(conn) do
      fun.(conn, user)
    else
      {:halt, conn} -> conn
    end
  end

  @doc "Runs `fun` only when passkeys are enabled (public ceremonies)."
  @spec with_enabled(Plug.Conn.t(), (Plug.Conn.t() -> Plug.Conn.t())) :: Plug.Conn.t()
  def with_enabled(conn, fun) do
    case ensure_enabled(conn) do
      {:ok, conn} -> fun.(conn)
      {:halt, conn} -> conn
    end
  end

  @doc """
  Answers `404`: JSON callers get a small error object, page requests get the
  shared page through the app layout.
  """
  @spec not_found(Plug.Conn.t()) :: Plug.Conn.t()
  def not_found(conn) do
    if json_request?(conn) do
      JSON.json(conn, 404, %{error: "not_found"})
    else
      conn
      |> put_status(:not_found)
      |> put_view(Cadence.ServerWeb.ErrorHTML)
      |> render("404.html")
    end
  end

  @doc """
  Responds to an anonymous request.

  Page requests redirect to `/sign-in`; JSON ceremony posts get a `401` so the
  browser script can show its own message instead of navigating away.
  """
  @spec unauthenticated(Plug.Conn.t()) :: Plug.Conn.t()
  def unauthenticated(conn) do
    if json_request?(conn) do
      JSON.json(conn, 401, %{error: "Sign in to manage security keys."})
    else
      conn
      |> put_flash(:error, "Sign in to manage security keys.")
      |> redirect(to: "/sign-in")
    end
  end

  @doc """
  True when the ceremony POST carried a JSON body.

  The `:browser` pipeline only accepts HTML, so `Accept` cannot be the
  discriminator. `passkeys.js` posts `application/json`; ordinary forms post
  `application/x-www-form-urlencoded`.
  """
  @spec json_request?(Plug.Conn.t()) :: boolean()
  def json_request?(conn) do
    case get_req_header(conn, "content-type") do
      [content_type | _rest] -> String.starts_with?(content_type, "application/json")
      [] -> false
    end
  end

  @doc """
  Sends a ceremony result, honouring the caller's format.

  JSON callers get `%{redirect_to: path}` on success or `%{error: message}` on
  failure; form callers get a redirect with a flash.
  """
  @spec respond(Plug.Conn.t(), :ok | :error, String.t(), String.t()) :: Plug.Conn.t()
  def respond(conn, :ok, message, path) do
    if json_request?(conn) do
      # Phoenix persists flash assigns only on redirects. A ceremony POST
      # answers JSON so `passkeys.js` can navigate, so write the same session
      # key directly; the destination page renders it as an ordinary flash.
      conn
      |> put_session("phoenix_flash", %{"info" => message})
      |> JSON.json(200, %{redirect_to: path})
    else
      conn
      |> put_flash(:info, message)
      |> redirect(to: path)
    end
  end

  def respond(conn, :error, message, path) do
    if json_request?(conn) do
      JSON.json(conn, 422, %{error: message})
    else
      conn
      |> put_flash(:error, message)
      |> redirect(to: path)
    end
  end
end
