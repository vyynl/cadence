defmodule Cadence.ServerWeb.SudoGate do
  @moduledoc """
  Controller guard for credential changes (spec §7.4).

  `with_sudo/3` runs the action only while the request's database session is
  inside the sudo window; otherwise it flashes `:message` and redirects through
  re-authentication with the caller's `:return_to`. An authenticated session
  alone is not enough: sudo is what keeps a stolen long-lived cookie from
  minting a daemon token or replacing a second factor.

      SudoGate.with_sudo(
        conn,
        [return_to: "/auth/tokens/new", message: "Re-authenticate to create a daemon token."],
        fn conn -> ... end
      )

  The guarded conn is returned in every case, so a controller action never
  leaks an internal tuple to the Phoenix plug stack. LiveView mutations use the
  page's own private sudo guard instead, because the sudo answer for a live
  render comes from the socket assign.
  """

  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]
  import Plug.Conn, only: [halt: 1]

  alias Cadence.ServerWeb.UserAuth

  @doc """
  Runs `fun` when the session is inside the sudo window, else redirects.

  `:return_to` must be a local path; both callers pass a fixed route, so the
  value is never client-controlled.
  """
  @spec with_sudo(Plug.Conn.t(), keyword(), (Plug.Conn.t() -> Plug.Conn.t())) :: Plug.Conn.t()
  def with_sudo(%Plug.Conn{} = conn, opts, fun) when is_function(fun, 1) do
    if UserAuth.sudo_mode?(conn.assigns[:current_session]) do
      fun.(conn)
    else
      return_to = Keyword.fetch!(opts, :return_to)
      message = Keyword.fetch!(opts, :message)

      conn
      |> put_flash(:error, message)
      |> redirect(to: "/sign-in?sudo=1&return_to=#{return_to}")
      |> halt()
    end
  end
end
