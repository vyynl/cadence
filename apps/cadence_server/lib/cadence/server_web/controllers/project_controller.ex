defmodule Cadence.ServerWeb.ProjectController do
  @moduledoc """
  Public, read-only project pages.

  Anonymous visitors see the preview node only (spec §7.1).
  """

  use Cadence.ServerWeb, :controller

  alias Cadence.Server.Portfolio

  def show(conn, %{"slug" => slug}) do
    case Portfolio.get_project_by_slug(slug) do
      {:ok, project} ->
        render(conn, :show,
          page_title: project.name,
          project: project,
          preview_node: Portfolio.preview_node(project.id)
        )

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(Cadence.ServerWeb.ErrorHTML)
        |> render("404.html")
    end
  end
end
