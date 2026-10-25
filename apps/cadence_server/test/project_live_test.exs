defmodule Cadence.ServerWeb.ProjectLiveTest do
  use Cadence.ServerWeb.ConnCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Cadence.Server.{ProjectGit, Repo}
  alias Cadence.Server.Accounts.User
  alias Cadence.Shared.{GitStore, Membership, Node, Project}

  setup do
    project = insert_project("demo")

    root =
      insert_node(project, %{message: "root node", flags: [:"in-progress"]}, %{
        "README.md" => "# Root\n",
        "src/root.ex" => "defmodule Root do\nend\n"
      })

    functioning =
      insert_node(
        project,
        %{parents: [root.id], message: "functioning node", flags: [:functioning]},
        %{
          "README.md" => "# Functioning\n\nThis readme is safe.\n",
          "src/app.ex" => "defmodule Demo do\n  def run, do: :ok\nend\n",
          "logo.bin" => <<0, 1, 2>>,
          "large.txt" => String.duplicate("a", 5000)
        }
      )

    broken =
      insert_node(
        project,
        %{parents: [root.id], message: "broken node", flags: [:broken]},
        %{"README.md" => "# Broken\n", "src/broken.ex" => "raise \"broken\"\n"}
      )

    sandbox =
      insert_node(
        project,
        %{parents: [root.id], message: "sandbox node", flags: [:sandbox]},
        %{"README.md" => "# Sandbox\n", "scratch.txt" => "notes\n"}
      )

    secret =
      insert_node(
        project,
        %{
          parents: [root.id],
          message: "deploy with token: ghp_abcdefghijklmnopqrstuvwxyz0123456789",
          flags: [:"in-progress"]
        },
        %{
          "README.md" => "# Secret\n",
          "config.txt" => "token: ghp_abcdefghijklmnopqrstuvwxyz0123456789\n"
        }
      )

    %{
      project: project,
      root: root,
      functioning: functioning,
      broken: broken,
      sandbox: sandbox,
      secret: secret
    }
  end

  test "renders the full public DAG, tree, and README", %{
    conn: conn,
    functioning: functioning
  } do
    {:ok, view, html} = live(conn, "/p/demo")

    assert html =~ "Demo"
    assert html =~ "root node"
    assert html =~ "functioning node"
    assert html =~ "broken node"
    assert html =~ "sandbox node"
    assert html =~ "dag-node intro default selected"
    assert has_element?(view, "a[href='/p/demo/n/#{functioning.id}']")
    assert html =~ "README.md"
    assert html =~ "src"
    assert html =~ "Functioning"
    refute html =~ "defmodule Demo"
  end

  test "navigates into a directory and a file", %{
    conn: conn,
    functioning: functioning
  } do
    {:ok, view, _html} = live(conn, "/p/demo")

    tree_html = render_patch(view, "/p/demo/n/#{functioning.id}/tree/src")
    assert tree_html =~ "app.ex"
    refute tree_html =~ "Functioning</h1>"

    file_html = render_patch(view, "/p/demo/n/#{functioning.id}/blob/src/app.ex")
    assert file_html =~ "defmodule Demo"
    assert file_html =~ "line-number"
    assert file_html =~ "src/app.ex"
  end

  test "renders canonical metadata for project and tree URLs", %{
    conn: conn,
    functioning: functioning
  } do
    {:ok, _view, html} = live(conn, "/p/demo")

    assert html =~ ~s(rel="canonical" href="http://localhost:4000/p/demo")
    assert html =~ ~s(name="description")

    {:ok, _view, tree_html} = live(conn, "/p/demo/n/#{functioning.id}/tree/src")
    assert tree_html =~ "http://localhost:4000/p/demo/n/#{functioning.id}/tree/src"
  end

  test "renders tree and blob URLs directly", %{conn: conn, functioning: functioning} do
    {:ok, _view, tree_html} = live(conn, "/p/demo/n/#{functioning.id}/tree/src")
    assert tree_html =~ "app.ex"

    {:ok, _view, file_html} = live(conn, "/p/demo/n/#{functioning.id}/blob/src/app.ex")
    assert file_html =~ "defmodule Demo"
  end

  test "shows binary and oversized file notices", %{
    conn: conn,
    functioning: functioning
  } do
    {:ok, view, _html} = live(conn, "/p/demo")

    assert render_patch(view, "/p/demo/n/#{functioning.id}/blob/logo.bin") =~
             "Binary file not shown."

    assert render_patch(view, "/p/demo/n/#{functioning.id}/blob/large.txt") =~
             "File too large to display."
  end

  test "quarantines a snapshot containing a secret", %{conn: conn, secret: secret} do
    {:ok, view, _html} = live(conn, "/p/demo")

    html = render_patch(view, "/p/demo/n/#{secret.id}")

    assert html =~ "Snapshot hidden for review"
    refute html =~ "config.txt"
    refute html =~ "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
  end

  test "quarantines a sensitive filename", %{conn: conn} do
    project = insert_project("env-project")

    env_node =
      insert_node(project, %{message: "env node"}, %{
        ".env" => "SAFE=1\n",
        "README.md" => "# Env\n"
      })

    {:ok, view, _html} = live(conn, "/p/env-project")
    html = render_patch(view, "/p/env-project/n/#{env_node.id}")

    assert html =~ "Snapshot hidden for review"
    refute html =~ ".env"
  end

  test "allows example env files but still renders safely", %{conn: conn} do
    project = insert_project("example-project")

    example_node =
      insert_node(project, %{message: "example env"}, %{
        ".env.example" => "TOKEN=placeholder\n",
        "README.md" => "# Example\n"
      })

    {:ok, view, _html} = live(conn, "/p/example-project")
    html = render_patch(view, "/p/example-project/n/#{example_node.id}")

    assert html =~ ".env.example"
    refute html =~ "Snapshot hidden for review"
  end

  test "does not render raw HTML from a README", %{conn: conn} do
    project = insert_project("xss-project")

    xss_node =
      insert_node(project, %{message: "xss node"}, %{
        "README.md" => "ok\n<script>alert('xss')</script>\n[x](javascript:alert(1))\n"
      })

    {:ok, view, _html} = live(conn, "/p/xss-project")
    html = render_patch(view, "/p/xss-project/n/#{xss_node.id}")

    refute html =~ "<script>alert"
    refute html =~ "javascript:"
    assert html =~ "ok"
  end

  describe "authenticated controls" do
    setup do
      owner = seed_user("owner@example.com", "Owner")
      trusted = seed_user("trusted@example.com", "Trusted")
      viewer = seed_user("viewer@example.com", "Viewer")
      project = insert_project("auth-demo", owner.id)
      insert_membership(project, owner, :owner)
      insert_membership(project, trusted, :trusted)
      insert_membership(project, viewer, :viewer)

      visible =
        insert_node(
          project,
          %{message: "visible node", flags: [:functioning]},
          %{"README.md" => "# Visible\n", "src/app.ex" => "defmodule App do\nend\n"}
        )

      secret =
        insert_node(
          project,
          %{message: "secret node", flags: [:"in-progress"]},
          %{
            "README.md" => "# Secret\n",
            "config.txt" => "token: ghp_abcdefghijklmnopqrstuvwxyz0123456789\n"
          }
        )

      %{
        owner: owner,
        trusted: trusted,
        viewer: viewer,
        project: project,
        visible: visible,
        secret: secret
      }
    end

    test "anonymous visitors get no controls or member list", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/p/auth-demo")

      refute html =~ "Pin node"
      refute html =~ "Show raw content"
      refute html =~ "Members ("
      refute html =~ "owner@example.com"
    end

    test "owners can pin and unpin nodes and see members", %{
      conn: conn,
      owner: owner,
      visible: visible
    } do
      {:ok, view, html} = live(signed_conn(conn, owner), "/p/auth-demo")

      assert html =~ "Pin node"
      assert html =~ "Show raw content"
      assert html =~ "Members (3)"
      assert html =~ "Owner"
      assert html =~ "Trusted"

      html = render_click(view, "toggle_pin", %{"id" => visible.id})
      assert html =~ "Unpin node"
      assert Repo.get!(Node, visible.id).pinned

      html = render_click(view, "toggle_pin", %{"id" => visible.id})
      assert html =~ "Pin node"
      refute Repo.get!(Node, visible.id).pinned
    end

    test "trusted members can reveal raw content but cannot pin", %{
      conn: conn,
      trusted: trusted,
      visible: visible
    } do
      {:ok, view, html} = live(signed_conn(conn, trusted), "/p/auth-demo")

      refute html =~ "Pin node"
      assert html =~ "Show raw content"
      assert html =~ "Members (3)"

      html = render_click(view, "toggle_pin", %{"id" => visible.id})
      assert html =~ "Only the project owner can pin nodes."
      refute Repo.get!(Node, visible.id).pinned
    end

    test "viewers get no owner/trusted controls", %{conn: conn, viewer: viewer} do
      {:ok, _view, html} = live(signed_conn(conn, viewer), "/p/auth-demo")

      refute html =~ "Pin node"
      refute html =~ "Show raw content"
      refute html =~ "Members ("
    end

    test "owner raw view reveals a quarantined snapshot and can be toggled off", %{
      conn: conn,
      owner: owner,
      secret: secret
    } do
      {:ok, view, html} =
        live(signed_conn(conn, owner), "/p/auth-demo/n/#{secret.id}/blob/config.txt")

      assert html =~ "Snapshot hidden for review"
      refute html =~ "ghp_abcdefghijklmnopqrstuvwxyz0123456789"

      html = render_click(view, "toggle_raw", %{})
      assert html =~ "Raw view — unfiltered content."
      assert html =~ "ghp_abcdefghijklmnopqrstuvwxyz0123456789"

      html = render_click(view, "toggle_raw", %{})
      assert html =~ "Snapshot hidden for review"
      refute html =~ "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
    end

    test "raw view resets when the selected node changes", %{
      conn: conn,
      owner: owner,
      visible: visible,
      secret: secret
    } do
      {:ok, view, _html} =
        live(signed_conn(conn, owner), "/p/auth-demo/n/#{secret.id}/blob/config.txt")

      html = render_click(view, "toggle_raw", %{})
      assert html =~ "Raw view — unfiltered content."

      html = render_patch(view, "/p/auth-demo/n/#{visible.id}")
      refute html =~ "Raw view — unfiltered content."
      assert html =~ "Show raw content"
    end

    test "viewer event injection cannot reveal raw content", %{
      conn: conn,
      viewer: viewer,
      secret: secret
    } do
      {:ok, view, _html} =
        live(signed_conn(conn, viewer), "/p/auth-demo/n/#{secret.id}/blob/config.txt")

      html = render_click(view, "toggle_raw", %{})

      refute html =~ "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
      assert html =~ "Only project owners and trusted members can view raw content."
    end
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

  test "redirects an unknown node to the project home", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/p/demo"}}} =
             live(conn, "/p/demo/n/#{Ecto.UUID.generate()}")
  end

  test "redacts secrets from commit messages", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/p/demo")

    refute html =~ "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
    assert html =~ "[REDACTED]"
  end

  test "renders an HTML 404 for an unknown route", %{conn: conn} do
    conn = get(conn, "/does-not-exist")

    assert conn.status == 404
    assert html_response(conn, 404) =~ "Page not found"
  end

  test "serves the LiveView browser assets", %{conn: conn} do
    assert conn |> get("/assets/vendor/phoenix.min.js") |> response(200) =~ "Phoenix"

    assert conn |> get("/assets/vendor/phoenix_live_view.min.js") |> response(200) =~
             "LiveView"

    assert conn |> get("/assets/js/app.js") |> response(200) =~ "LiveSocket"
    assert conn |> get("/assets/css/app.css") |> response(200) =~ ".project-home"
  end

  defp seed_user(email, name) do
    Ash.Seed.seed!(User, %{email: email, name: name})
  end

  defp insert_membership(project, user, role) do
    %Membership{}
    |> Membership.changeset(%{
      user_id: user.id,
      project_id: project.id,
      role: role
    })
    |> Repo.insert!()
  end

  defp signed_conn(conn, user) do
    {:ok, _token, claims} = AshAuthentication.Jwt.token_for_user(user)
    subject_name = AshAuthentication.Info.authentication_subject_name!(User)

    conn
    |> init_test_session(%{})
    |> put_session(to_string(subject_name), claims["jti"] <> ":" <> claims["sub"])
  end

  defp insert_project(slug, owner_id \\ Ecto.UUID.generate()) do
    %Project{}
    |> Project.changeset(%{
      name: "Demo",
      slug: slug,
      owner_id: owner_id
    })
    |> Repo.insert!()
  end

  defp insert_node(project, attrs, files) do
    commit = snapshot(project, files, attrs[:message] || "snapshot")

    attrs =
      Map.merge(
        %{
          project_id: project.id,
          git_commit_sha: commit,
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

  defp snapshot(project, files, message) do
    repo = ProjectGit.init(project.id)

    dir =
      Path.join(System.tmp_dir!(), "cadence_live_snapshot_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)

    Enum.each(files, fn {path, content} ->
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end)

    tree = GitStore.build_tree(repo, dir)

    commit =
      GitStore.write_commit(repo, tree, [], %{name: "test", email: "test@example.com"}, message)

    File.rm_rf!(dir)
    commit
  end
end
