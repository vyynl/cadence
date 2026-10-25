defmodule Cadence.ServerWeb.PortfolioController do
  @moduledoc """
  Landing page for the public portfolio.

  The project index lands in 3c; this slice establishes the route and layout.
  """

  use Cadence.ServerWeb, :controller

  def index(conn, _params) do
    render(conn, :index, page_title: "Cadence")
  end
end
