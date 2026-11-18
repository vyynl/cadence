defmodule Cadence.ServerWeb.Session do
  @moduledoc """
  `Plug.Session` with per-request options (spec §12.9).

  `Plug.Builder` evaluates a plug's options once at compile time, so the
  endpoint cannot pass a cookie flag that depends on the request host.
  `SessionOptions` decides that flag; this wrapper builds the options for each
  request so a public HTTPS origin and a private address can share one endpoint.
  """

  @behaviour Plug

  alias Cadence.ServerWeb.SessionOptions

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    Plug.Session.call(conn, Plug.Session.init(SessionOptions.cookie(conn.host)))
  end
end
