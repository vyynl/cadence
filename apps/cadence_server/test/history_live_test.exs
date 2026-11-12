defmodule Cadence.ServerWeb.HistoryLiveTest do
  use Cadence.ServerWeb.ConnCase, async: false

  import Cadence.ServerFixtures
  import Phoenix.LiveViewTest

  @token "ghp_abcdefghijklmnopqrstuvwxyz0123456789"

  describe "paging" do
    setup do
      project = project(Ecto.UUID.generate(), %{name: "History Demo", slug: "history-demo"})
      nodes = insert_nodes(project, 51)

      %{project: project, nodes: nodes, newest: List.last(nodes), oldest: hd(nodes)}
    end

    test "page 1 shows the newest 50 of 51 with an older link", %{
      conn: conn,
      project: project,
      newest: newest,
      oldest: oldest
    } do
      {:ok, view, _html} = live(conn, "/p/#{project.slug}/history")
      html = render_async(view)

      assert row_count(html) == 50
      assert has_element?(view, "#node-#{newest.id}")
      refute has_element?(view, "#node-#{oldest.id}")
      assert html =~ "Page 1 of 2"
      assert has_element?(view, "a[href='/p/#{project.slug}/history?page=2']", "Older →")
      refute has_element?(view, "a[href='/p/#{project.slug}/history?page=0']")
    end

    test "page 2 shows the oldest row with a newer link", %{
      conn: conn,
      project: project,
      newest: newest,
      oldest: oldest
    } do
      {:ok, view, _html} = live(conn, "/p/#{project.slug}/history?page=2")
      html = render_async(view)

      assert row_count(html) == 1
      assert has_element?(view, "#node-#{oldest.id}")
      refute has_element?(view, "#node-#{newest.id}")
      assert html =~ "Page 2 of 2"
      assert has_element?(view, "a[href='/p/#{project.slug}/history?page=1']", "← Newer")
      refute has_element?(view, "a[href='/p/#{project.slug}/history?page=3']")
    end

    test "junk pages fall back to page 1", %{conn: conn, project: project, newest: newest} do
      for query <- ["page=abc", "page=0", "page=-3"] do
        {:ok, view, _html} = live(conn, "/p/#{project.slug}/history?#{query}")
        html = render_async(view)

        assert has_element?(view, "#node-#{newest.id}")
        assert html =~ "Page 1 of 2"
        refute has_element?(view, "a[href='/p/#{project.slug}/history?page=0']")
      end
    end

    test "an out-of-range page clamps to the last page", %{
      conn: conn,
      project: project,
      oldest: oldest
    } do
      {:ok, view, _html} = live(conn, "/p/#{project.slug}/history?page=99")
      html = render_async(view)

      assert html =~ "Page 2 of 2"
      refute html =~ "No commits yet."
      assert has_element?(view, "#node-#{oldest.id}")
      assert row_count(html) == 1
    end
  end

  test "exactly 50 nodes render one page and no pager", %{conn: conn} do
    project = project(Ecto.UUID.generate(), %{name: "Full Page", slug: "history-full"})
    insert_nodes(project, 50)

    {:ok, view, _html} = live(conn, "/p/#{project.slug}/history")
    html = render_async(view)

    assert row_count(html) == 50
    refute has_element?(view, ".history-pager")
    refute html =~ "Older →"
    refute html =~ "← Newer"
  end

  test "an empty project says so on page 1 of 1", %{conn: conn} do
    project = project(Ecto.UUID.generate(), %{name: "Empty", slug: "history-empty"})

    {:ok, view, _html} = live(conn, "/p/#{project.slug}/history")
    html = render_async(view)

    assert html =~ "No commits yet."
    assert html =~ "Page 1 of 1"
    refute has_element?(view, ".history-list")
    refute has_element?(view, ".history-row")
  end

  test "an unknown project renders the 404 article", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/p/missing-history/history")

    assert html =~ "Project not found"
    assert html =~ "There is no project at this address."
    assert html =~ "Back to Cadence"
  end

  test "an anonymous visitor sees a redacted message, never the token", %{conn: conn} do
    project = project(Ecto.UUID.generate(), %{name: "Secrets", slug: "history-secrets"})

    node = insert_node(project, %{message: "deploy with token: #{@token}"})

    {:ok, view, _html} = live(conn, "/p/#{project.slug}/history")
    html = render_async(view)

    assert has_element?(view, "#node-#{node.id}")
    assert html =~ "[REDACTED]"
    refute html =~ @token
  end

  test "the author column shows imported names only, never the email", %{conn: conn} do
    project = project(Ecto.UUID.generate(), %{name: "Provenance", slug: "history-provenance"})

    imported =
      insert_node(project, %{
        message: "imported commit",
        created_at: ~U[2026-10-20 00:00:02Z],
        session_metadata: %{
          "import" => %{
            "source" => "git",
            "author" => "Ada Lovelace",
            "author_email" => "ada@example.com"
          }
        }
      })

    plain =
      insert_node(project, %{
        message: "local commit",
        created_at: ~U[2026-10-20 00:00:01Z]
      })

    {:ok, view, _html} = live(conn, "/p/#{project.slug}/history")
    html = render_async(view)

    assert has_element?(view, "#node-#{imported.id} .history-author", "Ada Lovelace")
    assert has_element?(view, "#node-#{plain.id} .history-author", "—")
    refute html =~ "ada@example.com"
  end

  test "every row links to its node and carries a stable id", %{conn: conn} do
    project = project(Ecto.UUID.generate(), %{name: "Links", slug: "history-links"})

    node =
      insert_node(project, %{
        message: "linked commit",
        git_commit_sha: String.duplicate("c", 40)
      })

    {:ok, view, _html} = live(conn, "/p/#{project.slug}/history")
    render_async(view)

    assert has_element?(view, "#node-#{node.id}")
    assert has_element?(view, "a.history-message[href='/p/#{project.slug}/n/#{node.id}']")
    assert has_element?(view, "a.history-sha[href='/p/#{project.slug}/n/#{node.id}']")
    assert has_element?(view, "#node-#{node.id} code", String.slice(node.git_commit_sha, 0, 12))
  end

  # Oldest first, one second apart, so the newest-first order is deterministic
  # without relying on insert timestamps.
  defp insert_nodes(project, count) do
    base = ~U[2026-10-20 00:00:00Z]

    Enum.map(1..count, fn index ->
      insert_node(project, %{
        message: "node #{String.pad_leading(Integer.to_string(index), 2, "0")}",
        created_at: DateTime.add(base, index, :second)
      })
    end)
  end

  defp insert_node(project, attrs) do
    node_fixture(project, Map.put_new(attrs, :git_commit_sha, String.duplicate("d", 40)))
  end

  defp row_count(html) do
    html
    |> String.split(~s(class="history-row"))
    |> length()
    |> Kernel.-(1)
  end
end
