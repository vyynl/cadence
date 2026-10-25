defmodule Cadence.ServerWeb.PortfolioPageTest do
  use Cadence.ServerWeb.ConnCase, async: false

  import Phoenix.ConnTest

  alias Cadence.Server.Repo
  alias Cadence.Shared.{Node, Project}

  test "renders the project portfolio with counts and metadata", %{conn: conn} do
    older = insert_project("older", "Older project", ~U[2026-10-20 00:00:00Z])
    newer = insert_project("newer", "Newer project", ~U[2026-10-24 00:00:00Z])

    insert_node(older)
    insert_node(newer)
    insert_node(newer)

    conn = get(conn, "/")
    html = html_response(conn, 200)

    assert html =~ "Newer project"
    assert html =~ "Older project"
    assert html =~ "/newer"
    assert html =~ "/older"
    assert html =~ "2 nodes"
    assert html =~ "1 node"
    assert html =~ ~s(rel="canonical" href="http://localhost:4000/")
    assert html =~ ~s(name="description")
    assert html =~ "Skip to content"
    refute html =~ "No public projects yet."
  end

  test "renders an empty portfolio", %{conn: conn} do
    html = conn |> get("/") |> html_response(200)

    assert html =~ "No public projects yet."
  end

  defp insert_project(slug, name, created_at) do
    %Project{}
    |> Project.changeset(%{
      name: name,
      slug: slug,
      owner_id: Ecto.UUID.generate(),
      created_at: created_at
    })
    |> Repo.insert!()
  end

  defp insert_node(project) do
    %Node{}
    |> Node.changeset(%{
      project_id: project.id,
      git_commit_sha: String.duplicate("d", 40),
      created_by: project.owner_id,
      created_at: DateTime.utc_now(),
      docs_state: :pending,
      flags: [:"in-progress"],
      message: "node"
    })
    |> Repo.insert!()
  end
end
