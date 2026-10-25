defmodule Cadence.ServerWeb.PortfolioController do
  @moduledoc """
  Public portfolio index.
  """

  use Cadence.ServerWeb, :controller

  alias Cadence.Server.Portfolio
  alias Cadence.ServerWeb.Metadata

  def index(conn, _params) do
    render(conn, :index,
      page_title: "Cadence",
      page_description: "A portfolio of local-first project histories.",
      canonical_url: Metadata.canonical("/"),
      projects: Portfolio.list_projects()
    )
  end
end
