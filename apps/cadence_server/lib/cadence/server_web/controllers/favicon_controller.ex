defmodule Cadence.ServerWeb.FaviconController do
  @moduledoc """
  Serves the SVG mark for `/favicon.ico`.

  Browsers request `/favicon.ico` even when the root layout links the SVG
  (`rel="icon"`); answering it keeps the console clean in older browsers. The
  linked `/assets/favicon.svg` is the primary source; this copy is inlined so
  the route has no filesystem input.
  """

  use Cadence.ServerWeb, :controller

  @svg """
  <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32" role="img" aria-label="Cadence">
    <rect width="32" height="32" rx="8" fill="#0969da"/>
    <path d="M12.5 14.9 19.6 11.2M12.5 17.1 19.6 20.8" stroke="#ffffff" stroke-width="2" stroke-linecap="round"/>
    <circle cx="10" cy="16" r="3" fill="#ffffff"/>
    <circle cx="22.6" cy="10.4" r="3" fill="#ffffff"/>
    <circle cx="22.6" cy="21.6" r="3" fill="#ffffff"/>
  </svg>
  """

  def index(conn, _params) do
    conn
    |> put_resp_content_type("image/svg+xml")
    |> put_resp_header("cache-control", "public, max-age=86400")
    |> send_resp(200, @svg)
  end
end
