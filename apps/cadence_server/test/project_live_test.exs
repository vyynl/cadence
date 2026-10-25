defmodule Cadence.ServerWeb.ProjectLiveTest do
  use Cadence.ServerWeb.ConnCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Cadence.Server.Repo
  alias Cadence.Shared.{Node, Project}

  setup do
    project = insert_project("demo")

    root =
      insert_node(project, %{
        message: "root node",
        flags: [:"in-progress"],
        created_at: ~U[2026-10-20 10:00:00.000000Z]
      })

    functioning =
      insert_node(project, %{
        parents: [root.id],
        message: "functioning node",
        flags: [:functioning],
        created_at: ~U[2026-10-21 10:00:00.000000Z]
      })

    broken =
      insert_node(project, %{
        parents: [root.id],
        message: "broken node",
        flags: [:broken],
        created_at: ~U[2026-10-22 10:00:00.000000Z]
      })

    sandbox =
      insert_node(project, %{
        parents: [root.id],
        message: "sandbox node",
        flags: [:sandbox],
        created_at: ~U[2026-10-23 10:00:00.000000Z]
      })

    secret =
      insert_node(project, %{
        parents: [root.id],
        message: "deploy with token: ghp_abcdefghijklmnopqrstuvwxyz0123456789",
        flags: [:"in-progress"],
        created_at: ~U[2026-10-24 10:00:00.000000Z]
      })

    %{
      project: project,
      root: root,
      functioning: functioning,
      broken: broken,
      sandbox: sandbox,
      secret: secret
    }
  end

  test "renders the full public DAG and default node", %{conn: conn, functioning: functioning} do
    {:ok, view, html} = live(conn, "/p/demo")

    assert html =~ "Demo"
    assert html =~ "root node"
    assert html =~ "functioning node"
    assert html =~ "broken node"
    assert html =~ "sandbox node"
    assert html =~ "Repository browser lands in 3b-2."
    assert html =~ "dag-node intro default selected"
    assert has_element?(view, "a[href='/p/demo/n/#{functioning.id}']")
  end

  test "selects a node in place with a patch", %{conn: conn, broken: broken} do
    {:ok, view, _html} = live(conn, "/p/demo")

    html = render_patch(view, "/p/demo/n/#{broken.id}")

    assert html =~ "broken node"
    assert html =~ "dag-node rest selected"
    assert html =~ "broken"
  end

  test "renders the empty state", %{conn: conn} do
    insert_project("empty")
    {:ok, _view, html} = live(conn, "/p/empty")

    assert html =~ "No commits yet."
  end

  test "renders a not-found page for an unknown project", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/p/missing")

    assert html =~ "Project not found"
    assert html =~ "Back to Cadence"
  end

  test "renders an HTML 404 for an unknown route", %{conn: conn} do
    conn = get(conn, "/does-not-exist")

    assert conn.status == 404
    assert html_response(conn, 404) =~ "Page not found"
  end

  test "redirects an unknown node to the project home", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/p/demo"}}} =
             live(conn, "/p/demo/n/#{Ecto.UUID.generate()}")
  end

  test "redacts secrets from commit messages", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/p/demo")

    refute html =~ "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
    assert html =~ "[REDACTED]"
  end

  test "serves the LiveView browser assets", %{conn: conn} do
    assert conn |> get("/assets/vendor/phoenix.min.js") |> response(200) =~ "Phoenix"

    assert conn |> get("/assets/vendor/phoenix_live_view.min.js") |> response(200) =~
             "LiveView"

    assert conn |> get("/assets/js/app.js") |> response(200) =~ "LiveSocket"
    assert conn |> get("/assets/css/app.css") |> response(200) =~ ".project-home"
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
          git_commit_sha: String.duplicate("c", 40),
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
