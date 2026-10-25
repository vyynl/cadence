defmodule Cadence.ServerWeb.ProjectPageTest do
  use Cadence.ServerWeb.ConnCase, async: false

  import Phoenix.ConnTest

  alias Cadence.Server.Repo
  alias Cadence.Shared.{Node, Project}

  describe "GET /" do
    test "renders the landing page", %{conn: conn} do
      body = conn |> get("/") |> html_response(200)
      assert body =~ "Version control for sessions"
    end
  end

  describe "GET /p/:slug" do
    test "renders the project preview node", %{conn: conn} do
      project = insert_project("demo")

      node =
        insert_node(project, %{
          flags: [:functioning],
          message: "Ship the read-only page",
          created_at: ~U[2026-10-24 12:34:56.000000Z]
        })

      conn = get(conn, "/p/demo")

      body = html_response(conn, 200)
      assert body =~ "Demo"
      assert body =~ "/demo"
      assert body =~ "Ship the read-only page"
      assert body =~ "functioning"
      assert body =~ "2026-10-24 12:34:56 UTC"
      assert body =~ String.slice(node.git_commit_sha, 0, 12)
    end

    test "renders an empty state when the project has no nodes", %{conn: conn} do
      insert_project("empty")

      body = conn |> get("/p/empty") |> html_response(200)
      assert body =~ "No commits yet."
    end

    test "only exposes the preview node publicly", %{conn: conn} do
      project = insert_project("private")

      insert_node(project, %{
        flags: [:functioning],
        message: "public preview",
        created_at: ~U[2026-10-20 00:00:00Z]
      })

      insert_node(project, %{
        flags: [:broken],
        message: "broken work in progress",
        created_at: ~U[2026-10-24 00:00:00Z]
      })

      body = conn |> get("/p/private") |> html_response(200)

      assert body =~ "public preview"
      refute body =~ "broken work in progress"
    end

    test "returns an HTML 404 for an unknown project", %{conn: conn} do
      conn = get(conn, "/p/does-not-exist")

      assert conn.status == 404
      assert html_response(conn, 404) =~ "Page not found"
    end
  end

  defp insert_project(slug) do
    %Project{}
    |> Project.changeset(%{
      name: "Demo",
      slug: slug,
      owner_id: Ecto.UUID.generate()
    })
    |> Repo.insert!()
  end

  defp insert_node(project, attrs) do
    attrs =
      Map.merge(
        %{
          project_id: project.id,
          git_commit_sha: String.duplicate("b", 40),
          created_by: project.owner_id,
          created_at: DateTime.utc_now(),
          docs_state: :pending,
          flags: [:"in-progress"],
          message: "node"
        },
        attrs
      )

    %Node{}
    |> Node.changeset(attrs)
    |> Repo.insert!()
  end
end
