defmodule Cadence.ServerWeb.ProjectLiveTest do
  use Cadence.ServerWeb.ConnCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Cadence.Server.{Incidents, ProjectGit, Repo}
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
    assert has_element?(view, "div#node-pane-#{functioning.id}-node-[phx-update=replace]")
    assert has_element?(view, "section.repo-panel.reveal")
    assert html =~ "--pane-delay:"
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
    assert has_element?(view, "div#node-pane-#{functioning.id}-tree-src[phx-update=replace]")

    file_html = render_patch(view, "/p/demo/n/#{functioning.id}/blob/src/app.ex")
    assert file_html =~ "defmodule Demo"
    assert file_html =~ "line-number"
    assert file_html =~ "src/app.ex"

    assert has_element?(
             view,
             "div#node-pane-#{functioning.id}-blob-src-app-ex[phx-update=replace]"
           )
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

  describe "docs state badge" do
    test "renders the selected node's own docs state", %{conn: conn} do
      project = insert_project("docs-states")

      pending =
        insert_node(project, %{message: "pending docs", docs_state: :pending}, %{
          "README.md" => "# Pending\n"
        })

      current =
        insert_node(
          project,
          %{message: "current docs", parents: [pending.id], docs_state: :current},
          %{"README.md" => "# Current\n"}
        )

      skipped =
        insert_node(
          project,
          %{message: "skipped docs", parents: [pending.id], docs_state: :skipped},
          %{"README.md" => "# Skipped\n"}
        )

      {:ok, view, _html} = live(conn, "/p/docs-states")

      pending_html = render_patch(view, "/p/docs-states/n/#{pending.id}")
      assert pending_html =~ "docs pending"
      assert pending_html =~ "docs-badge docs-pending"
      refute pending_html =~ "child node"

      assert render_patch(view, "/p/docs-states/n/#{current.id}") =~ "docs current"

      skipped_html = render_patch(view, "/p/docs-states/n/#{skipped.id}")
      assert skipped_html =~ "docs skipped"
      assert skipped_html =~ "docs-badge docs-skipped"
    end

    test "links a follow-up docs child without claiming the snapshot has docs", %{conn: conn} do
      project = insert_project("docs-child")

      code =
        insert_node(
          project,
          %{message: "code node", docs_state: :pending},
          %{"README.md" => "# Code\n"}
        )

      child =
        insert_node(
          project,
          %{
            message: "docs: update project documentation",
            parents: [code.id],
            docs_state: :current,
            session_metadata: %{"docs" => %{"docs_for" => code.id}}
          },
          %{"README.md" => "# Docs\n"}
        )

      {:ok, view, _html} = live(conn, "/p/docs-child")

      html = render_patch(view, "/p/docs-child/n/#{code.id}")

      assert html =~ "docs pending"
      assert html =~ "docs current · child node"

      assert has_element?(
               view,
               "a.docs-badge.docs-current[href='/p/docs-child/n/#{child.id}']",
               "docs current · child node"
             )
    end

    test "a docs child pushed while the code node is open appears live", %{conn: conn} do
      project = insert_project("docs-child-live")

      code =
        insert_node(
          project,
          %{message: "code node", docs_state: :pending},
          %{"README.md" => "# Code\n"}
        )

      {:ok, view, _html} = live(conn, "/p/docs-child-live")

      refute render_patch(view, "/p/docs-child-live/n/#{code.id}") =~ "child node"

      child =
        insert_node(
          project,
          %{
            message: "docs: update project documentation",
            parents: [code.id],
            docs_state: :current,
            session_metadata: %{"docs" => %{"docs_for" => code.id}}
          },
          %{"README.md" => "# Docs\n"}
        )

      Phoenix.PubSub.broadcast(
        Cadence.Server.PubSub,
        "project:#{project.id}",
        {:nodes_pushed, project.id, [child.id]}
      )

      html = render(view)

      assert html =~ "docs current · child node"

      assert has_element?(
               view,
               "a.docs-badge.docs-current[href='/p/docs-child-live/n/#{child.id}']",
               "docs current · child node"
             )
    end

    test "a docs child does not link to itself", %{conn: conn} do
      project = insert_project("docs-child-self")

      code =
        insert_node(project, %{message: "code node", docs_state: :pending}, %{
          "README.md" => "# Code\n"
        })

      child =
        insert_node(
          project,
          %{
            message: "docs: update project documentation",
            parents: [code.id],
            docs_state: :current,
            session_metadata: %{"docs" => %{"docs_for" => code.id}}
          },
          %{"README.md" => "# Docs\n"}
        )

      {:ok, view, _html} = live(conn, "/p/docs-child-self")

      html = render_patch(view, "/p/docs-child-self/n/#{child.id}")

      assert html =~ "docs current"
      refute html =~ "child node"
    end
  end

  describe "actions panel" do
    test "a member sees the snapshot's action list", %{conn: conn} do
      owner = seed_user("actions-live-owner@example.com", "Owner")
      project = insert_project("actions-live", owner.id)
      insert_membership(project, owner, :owner)

      node =
        insert_node(
          project,
          %{message: "action node", flags: [:functioning]},
          %{"actions/manifest.json" => actions_manifest(), "README.md" => "# Actions\n"}
        )

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/actions-live")
      html = render_patch(view, "/p/actions-live/n/#{node.id}")

      assert html =~ "Actions"
      assert html =~ "run_analysis"
      assert html =~ "Run the analysis"
      assert html =~ "python actions/run.py"
    end

    test "a viewer may see the list", %{conn: conn} do
      owner = seed_user("actions-viewer-owner@example.com", "Owner")
      viewer = seed_user("actions-viewer-member@example.com", "Viewer")
      project = insert_project("actions-viewer", owner.id)
      insert_membership(project, owner, :owner)
      insert_membership(project, viewer, :viewer)

      node =
        insert_node(
          project,
          %{message: "action node", flags: [:functioning]},
          %{"actions/manifest.json" => actions_manifest()}
        )

      {:ok, view, _html} = live(signed_conn(conn, viewer), "/p/actions-viewer")
      html = render_patch(view, "/p/actions-viewer/n/#{node.id}")

      assert html =~ "run_analysis"
    end

    test "anonymous visitors see no action panel", %{conn: conn} do
      project = insert_project("actions-public")

      node =
        insert_node(
          project,
          %{message: "action node", flags: [:functioning]},
          %{"actions/manifest.json" => actions_manifest()}
        )

      {:ok, view, _html} = live(conn, "/p/actions-public")
      html = render_patch(view, "/p/actions-public/n/#{node.id}")

      refute html =~ "run_analysis"
      refute html =~ "python actions/run.py"
    end

    test "a quarantined snapshot hides its actions", %{conn: conn} do
      owner = seed_user("actions-quarantine-owner@example.com", "Owner")
      project = insert_project("actions-quarantine", owner.id)
      insert_membership(project, owner, :owner)

      node =
        insert_node(
          project,
          %{message: "secret action node", flags: [:functioning]},
          %{
            "actions/manifest.json" => actions_manifest(),
            "config.txt" => "token: ghp_abcdefghijklmnopqrstuvwxyz0123456789\n"
          }
        )

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/actions-quarantine")
      html = render_patch(view, "/p/actions-quarantine/n/#{node.id}")

      assert html =~ "Snapshot hidden for review"
      refute html =~ "run_analysis"
    end

    test "a malformed manifest renders a shape-only notice", %{conn: conn} do
      owner = seed_user("actions-invalid-owner@example.com", "Owner")
      project = insert_project("actions-invalid", owner.id)
      insert_membership(project, owner, :owner)

      node =
        insert_node(
          project,
          %{message: "bad manifest", flags: [:functioning]},
          %{"actions/manifest.json" => "{not json"}
        )

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/actions-invalid")
      html = render_patch(view, "/p/actions-invalid/n/#{node.id}")

      assert html =~ "The actions manifest could not be read."
      refute html =~ "run_analysis"
    end

    test "CAD_ACTIONS_ENABLED=false hides the panel", %{conn: conn} do
      owner = seed_user("actions-disabled-owner@example.com", "Owner")
      project = insert_project("actions-disabled", owner.id)
      insert_membership(project, owner, :owner)

      node =
        insert_node(
          project,
          %{message: "action node", flags: [:functioning]},
          %{"actions/manifest.json" => actions_manifest()}
        )

      Application.put_env(:cadence_server, :actions_enabled, false)
      on_exit(fn -> Application.delete_env(:cadence_server, :actions_enabled) end)

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/actions-disabled")
      html = render_patch(view, "/p/actions-disabled/n/#{node.id}")

      refute html =~ "run_analysis"
      refute html =~ "The actions manifest could not be read."
    end

    test "a snapshot without a manifest hides the panel", %{conn: conn} do
      owner = seed_user("actions-none-owner@example.com", "Owner")
      project = insert_project("actions-none", owner.id)
      insert_membership(project, owner, :owner)

      node =
        insert_node(project, %{message: "plain node", flags: [:functioning]}, %{
          "README.md" => "# No actions\n"
        })

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/actions-none")
      html = render_patch(view, "/p/actions-none/n/#{node.id}")

      refute html =~ "run_analysis"
      refute html =~ "The actions manifest could not be read."
    end

    test "a signed-in non-member sees no action panel", %{conn: conn} do
      owner = seed_user("actions-outsider-owner@example.com", "Owner")
      outsider = seed_user("actions-outsider@example.com", "Outsider")
      project = insert_project("actions-outsider", owner.id)
      insert_membership(project, owner, :owner)

      node =
        insert_node(
          project,
          %{message: "action node", flags: [:functioning]},
          %{"actions/manifest.json" => actions_manifest()}
        )

      {:ok, view, _html} = live(signed_conn(conn, outsider), "/p/actions-outsider")
      html = render_patch(view, "/p/actions-outsider/n/#{node.id}")

      refute html =~ "run_analysis"
    end

    test "an oversized manifest renders a shape-only notice", %{conn: conn} do
      owner = seed_user("actions-oversize-owner@example.com", "Owner")
      project = insert_project("actions-oversize", owner.id)
      insert_membership(project, owner, :owner)

      node =
        insert_node(
          project,
          %{message: "action node", flags: [:functioning]},
          %{"actions/manifest.json" => actions_manifest()}
        )

      Application.put_env(:cadence_server, :actions_max_manifest_bytes, 10)
      on_exit(fn -> Application.delete_env(:cadence_server, :actions_max_manifest_bytes) end)

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/actions-oversize")
      html = render_patch(view, "/p/actions-oversize/n/#{node.id}")

      assert html =~ "The actions manifest could not be read."
      refute html =~ "run_analysis"
    end

    test "resolving a node incident reveals the action panel live", %{conn: conn} do
      owner = seed_user("actions-live-owner@example.com", "Owner")
      project = insert_project("actions-live-unquarantine", owner.id)
      insert_membership(project, owner, :owner)

      node =
        insert_node(
          project,
          %{message: "clean action node", flags: [:functioning]},
          %{"actions/manifest.json" => actions_manifest(), "README.md" => "# Clean\n"}
        )

      incident = open_secret_incident(project, node)

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/actions-live-unquarantine")
      html = render_patch(view, "/p/actions-live-unquarantine/n/#{node.id}")

      assert html =~ "Snapshot hidden for review"
      refute html =~ "run_analysis"

      assert {:ok, _resolved} = Incidents.resolve(%{id: owner.id}, project.id, incident.id)

      html = render(view)
      assert html =~ "run_analysis"
      refute html =~ "Snapshot hidden for review"
    end

    test "raw view reveals and re-hides a quarantined snapshot's actions", %{conn: conn} do
      owner = seed_user("actions-raw-owner@example.com", "Owner")
      project = insert_project("actions-raw", owner.id)
      insert_membership(project, owner, :owner)

      node =
        insert_node(
          project,
          %{message: "secret action node", flags: [:functioning]},
          %{
            "actions/manifest.json" => actions_manifest(),
            "config.txt" => "token: ghp_abcdefghijklmnopqrstuvwxyz0123456789\n"
          }
        )

      {:ok, view, html} =
        live(signed_conn(conn, owner), "/p/actions-raw/n/#{node.id}")

      assert html =~ "Snapshot hidden for review"
      refute html =~ "run_analysis"

      html = render_click(view, "toggle_raw", %{})
      assert html =~ "run_analysis"
      refute html =~ "Snapshot hidden for review"

      html = render_click(view, "toggle_raw", %{})
      assert html =~ "Snapshot hidden for review"
      refute html =~ "run_analysis"
    end
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
    assert html =~ ~s(class="quarantine-notice callout callout-protected")
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

  describe "node incidents" do
    test "an open critical incident hides a clean snapshot", %{conn: conn} do
      project = insert_project("incident-project")
      clean = insert_node(project, %{message: "clean node"}, %{"README.md" => "# Clean\n"})
      open_secret_incident(project, clean)

      {:ok, view, _html} = live(conn, "/p/incident-project")
      html = render_patch(view, "/p/incident-project/n/#{clean.id}")

      assert html =~ "Snapshot hidden for review"
      refute html =~ "README.md"
    end

    test "resolving the incident makes the clean snapshot visible again", %{conn: conn} do
      owner = seed_user("incident-resolve@example.com", "Owner")
      project = insert_project("incident-resolve", owner.id)
      insert_membership(project, owner, :owner)

      clean =
        insert_node(project, %{message: "clean node"}, %{"README.md" => "# Clean\n"})

      incident = open_secret_incident(project, clean)
      assert {:ok, _resolved} = Incidents.resolve(%{id: owner.id}, project.id, incident.id)

      {:ok, view, _html} = live(conn, "/p/incident-resolve")
      html = render_patch(view, "/p/incident-resolve/n/#{clean.id}")

      refute html =~ "Snapshot hidden for review"
      assert html =~ "README.md"
    end

    test "a secret snapshot stays hidden after its incident is resolved", %{conn: conn} do
      owner = seed_user("incident-secret@example.com", "Owner")
      project = insert_project("incident-secret", owner.id)
      insert_membership(project, owner, :owner)

      secret =
        insert_node(project, %{message: "secret node"}, %{
          "config.txt" => "token: ghp_abcdefghijklmnopqrstuvwxyz0123456789\n"
        })

      incident = open_secret_incident(project, secret)
      assert {:ok, _resolved} = Incidents.resolve(%{id: owner.id}, project.id, incident.id)

      {:ok, view, _html} = live(conn, "/p/incident-secret")
      html = render_patch(view, "/p/incident-secret/n/#{secret.id}")

      assert html =~ "Snapshot hidden for review"
      refute html =~ "config.txt"
    end

    test "owner raw view still bypasses incident-driven quarantine", %{conn: conn} do
      owner = seed_user("incident-owner@example.com", "Owner")
      project = insert_project("incident-raw", owner.id)
      insert_membership(project, owner, :owner)

      clean = insert_node(project, %{message: "clean node"}, %{"README.md" => "# Clean\n"})
      open_secret_incident(project, clean)

      {:ok, view, html} = live(signed_conn(conn, owner), "/p/incident-raw/n/#{clean.id}")
      assert html =~ "Snapshot hidden for review"
      refute html =~ "README.md"

      html = render_click(view, "toggle_raw", %{})
      assert html =~ "Raw view — unfiltered content."
      assert html =~ "README.md"
      refute html =~ "Snapshot hidden for review"
    end
  end

  describe "node incident freshness" do
    test "an incident opened elsewhere hides the selected snapshot live", %{conn: conn} do
      project = insert_project("live-incident-open")
      clean = insert_node(project, %{message: "clean node"}, %{"README.md" => "# Clean\n"})

      {:ok, view, _html} = live(conn, "/p/live-incident-open")
      html = render_patch(view, "/p/live-incident-open/n/#{clean.id}")
      assert html =~ "README.md"
      refute html =~ "Snapshot hidden for review"

      open_secret_incident(project, clean)

      html = render(view)
      assert html =~ "Snapshot hidden for review"
      refute html =~ "README.md"
    end

    test "resolving the incident elsewhere restores the clean snapshot live", %{conn: conn} do
      owner = seed_user("live-resolve@example.com", "Owner")
      project = insert_project("live-incident-resolve", owner.id)
      insert_membership(project, owner, :owner)

      clean = insert_node(project, %{message: "clean node"}, %{"README.md" => "# Clean\n"})
      incident = open_secret_incident(project, clean)

      {:ok, view, _html} = live(conn, "/p/live-incident-resolve")

      assert render_patch(view, "/p/live-incident-resolve/n/#{clean.id}") =~
               "Snapshot hidden for review"

      assert {:ok, _resolved} = Incidents.resolve(%{id: owner.id}, project.id, incident.id)

      html = render(view)
      refute html =~ "Snapshot hidden for review"
      assert html =~ "README.md"

      # Re-patching the same node must reuse the recomputed answer, not the
      # cached :quarantined one (the cache key includes the incident flag).
      html = render_patch(view, "/p/live-incident-resolve/n/#{clean.id}")
      refute html =~ "Snapshot hidden for review"
      assert html =~ "README.md"
    end

    test "a secret snapshot stays hidden after an external resolution", %{conn: conn} do
      owner = seed_user("live-secret@example.com", "Owner")
      project = insert_project("live-incident-secret", owner.id)
      insert_membership(project, owner, :owner)

      secret =
        insert_node(project, %{message: "secret node"}, %{
          "config.txt" => "token: ghp_abcdefghijklmnopqrstuvwxyz0123456789\n"
        })

      incident = open_secret_incident(project, secret)

      {:ok, view, _html} = live(conn, "/p/live-incident-secret")

      assert render_patch(view, "/p/live-incident-secret/n/#{secret.id}") =~
               "Snapshot hidden for review"

      assert {:ok, _resolved} = Incidents.resolve(%{id: owner.id}, project.id, incident.id)

      html = render(view)
      assert html =~ "Snapshot hidden for review"
      refute html =~ "config.txt"
    end

    test "raw view is not hidden by an incident event", %{conn: conn} do
      owner = seed_user("live-raw@example.com", "Owner")
      project = insert_project("live-incident-raw", owner.id)
      insert_membership(project, owner, :owner)

      clean = insert_node(project, %{message: "clean node"}, %{"README.md" => "# Clean\n"})

      {:ok, view, html} = live(signed_conn(conn, owner), "/p/live-incident-raw/n/#{clean.id}")
      refute html =~ "Snapshot hidden for review"

      assert render_click(view, "toggle_raw", %{}) =~ "Raw view — unfiltered content."

      open_secret_incident(project, clean)

      html = render(view)
      assert html =~ "Raw view — unfiltered content."
      assert html =~ "README.md"
      refute html =~ "Snapshot hidden for review"
    end

    test "patching back to the same node recomputes the quarantine answer", %{conn: conn} do
      project = insert_project("live-incident-cache")
      clean = insert_node(project, %{message: "clean node"}, %{"README.md" => "# Clean\n"})

      {:ok, view, _html} = live(conn, "/p/live-incident-cache")
      assert render_patch(view, "/p/live-incident-cache/n/#{clean.id}") =~ "README.md"

      open_secret_incident(project, clean)
      assert render(view) =~ "Snapshot hidden for review"

      # The same URL again must not reuse the earlier clean answer: the node id
      # is only one of the inputs (Iron Law 5).
      html = render_patch(view, "/p/live-incident-cache/n/#{clean.id}")
      assert html =~ "Snapshot hidden for review"
      refute html =~ "README.md"
    end

    test "a failed snapshot scan is retried on the next incident event", %{conn: conn} do
      project = insert_project("live-scan-retry")
      clean = insert_node(project, %{message: "clean node"}, %{"README.md" => "# Clean\n"})

      previous = Application.get_env(:cadence_server, :scan_max_files)
      Application.put_env(:cadence_server, :scan_max_files, 0)

      on_exit(fn ->
        if previous == nil do
          Application.delete_env(:cadence_server, :scan_max_files)
        else
          Application.put_env(:cadence_server, :scan_max_files, previous)
        end
      end)

      {:ok, view, _html} = live(conn, "/p/live-scan-retry")

      html = render_patch(view, "/p/live-scan-retry/n/#{clean.id}")
      assert html =~ "Snapshot hidden for review"
      refute html =~ "README.md"

      # The snapshot becomes readable again. A high (non-blocking) incident
      # keeps the cache key identical, so only a non-cacheable failure answer
      # allows the scan to be retried.
      Application.put_env(:cadence_server, :scan_max_files, 1_000)

      {:ok, _incident} =
        Incidents.open(%{
          project_id: project.id,
          node_id: clean.id,
          kind: :scan_incomplete,
          severity: :high,
          title: "Scan notice",
          details: %{reason: :too_many_files}
        })

      html = render(view)
      refute html =~ "Snapshot hidden for review"
      assert html =~ "README.md"
    end

    test "an incident for another node does not disturb the selected pane", %{conn: conn} do
      project = insert_project("live-incident-other")

      selected =
        insert_node(project, %{message: "selected node"}, %{"README.md" => "# Selected\n"})

      other = insert_node(project, %{message: "other node"}, %{"other.txt" => "other\n"})

      {:ok, view, _html} = live(conn, "/p/live-incident-other")
      assert render_patch(view, "/p/live-incident-other/n/#{selected.id}") =~ "README.md"

      open_secret_incident(project, other)

      html = render(view)
      refute html =~ "Snapshot hidden for review"
      assert html =~ "README.md"
    end
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

    test "a malformed run_action payload is refused without navigating", %{
      conn: conn,
      owner: owner,
      visible: visible
    } do
      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/auth-demo")
      render_patch(view, "/p/auth-demo/n/#{visible.id}")

      html = render_click(view, "run_action", %{})

      assert html =~ "Only the project owner or a trusted member can run actions."
      assert has_element?(view, "div#node-pane-#{visible.id}-node-")
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

  describe "DAG scale" do
    test "caps the DAG and shows the note only past the cap", %{conn: conn} do
      put_config(:dag_max_nodes, 2)
      project = insert_project("dag-cap")

      first =
        insert_bare_node(project, %{message: "cap one", created_at: ~U[2026-10-20 00:00:00Z]})

      second =
        insert_bare_node(project, %{
          message: "cap two",
          parents: [first.id],
          created_at: ~U[2026-10-21 00:00:00Z]
        })

      {:ok, _view, html} = live(conn, "/p/dag-cap")

      assert dag_node_count(html) == 2
      refute html =~ "Showing the newest"

      insert_bare_node(project, %{
        message: "cap three",
        parents: [second.id],
        created_at: ~U[2026-10-22 00:00:00Z]
      })

      {:ok, view, html} = live(conn, "/p/dag-cap")

      assert dag_node_count(html) == 2
      assert length(Regex.scan(~r/class="dag-edge /, html)) == 1
      assert html =~ "Showing the newest 2 of 3 commits."
      assert html =~ "cap three"
      refute html =~ "cap one"
      assert has_element?(view, "a[href='/p/dag-cap/history']", "Browse the full history")
    end

    test "does not link the history page while the whole DAG renders", %{conn: conn} do
      put_config(:dag_max_nodes, 2)
      project = insert_project("dag-no-cap")
      insert_bare_nodes(project, 2)

      {:ok, _view, html} = live(conn, "/p/dag-no-cap")

      refute html =~ "Showing the newest"
      refute html =~ "/p/dag-no-cap/history"
    end

    test "skips the intro above dag_intro_max_nodes", %{conn: conn} do
      put_config(:dag_intro_ms, 1000)
      put_config(:dag_intro_max_nodes, 60)

      at_threshold = insert_project("intro-60")
      insert_bare_nodes(at_threshold, 60)

      {:ok, _view, html} = live(conn, "/p/intro-60")

      assert html =~ "--pane-delay: 950ms"

      above_threshold = insert_project("intro-61")
      insert_bare_nodes(above_threshold, 61)

      {:ok, _view, html} = live(conn, "/p/intro-61")

      assert html =~ "--pane-delay: 0ms"
    end

    test "a deep link to a node older than the cap still renders the pane", %{conn: conn} do
      put_config(:dag_max_nodes, 2)
      project = insert_project("dag-deep-link")

      old =
        insert_bare_node(project, %{
          message: "old deploy token: ghp_abcdefghijklmnopqrstuvwxyz0123456789",
          created_at: ~U[2026-10-20 00:00:00Z]
        })

      insert_bare_node(project, %{message: "middle", created_at: ~U[2026-10-21 00:00:00Z]})
      insert_bare_node(project, %{message: "newest", created_at: ~U[2026-10-22 00:00:00Z]})

      {:ok, view, html} = live(conn, "/p/dag-deep-link/n/#{old.id}")

      assert has_element?(view, "div#node-pane-#{old.id}-node-[phx-update=replace]")
      assert html =~ "[REDACTED]"
      refute html =~ "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
      assert html =~ "Showing the newest 2 of 3 commits."
    end

    test "a pinned node older than the cap is still the default selection", %{conn: conn} do
      put_config(:dag_max_nodes, 2)
      project = insert_project("dag-pinned-old")

      pinned =
        insert_bare_node(project, %{
          message: "pinned old",
          pinned: true,
          created_at: ~U[2026-10-20 00:00:00Z]
        })

      insert_bare_node(project, %{message: "middle", created_at: ~U[2026-10-21 00:00:00Z]})
      insert_bare_node(project, %{message: "newest", created_at: ~U[2026-10-22 00:00:00Z]})

      {:ok, view, html} = live(conn, "/p/dag-pinned-old")

      assert has_element?(view, "div#node-pane-#{pinned.id}-node-[phx-update=replace]")
      assert html =~ "pinned old"
    end

    test "an event after selecting a node older than the cap keeps it selected", %{conn: conn} do
      put_config(:dag_max_nodes, 2)
      owner = seed_user("dag-retain@example.com", "Owner")
      project = insert_project("dag-retain", owner.id)
      insert_membership(project, owner, :owner)

      old =
        insert_node(
          project,
          %{message: "old selected", created_at: ~U[2026-10-20 00:00:00Z]},
          %{"README.md" => "# Old\n"}
        )

      insert_node(
        project,
        %{message: "middle", created_at: ~U[2026-10-21 00:00:00Z]},
        %{"README.md" => "# Middle\n"}
      )

      newest =
        insert_node(
          project,
          %{message: "newest", created_at: ~U[2026-10-22 00:00:00Z]},
          %{"README.md" => "# Newest\n"}
        )

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/dag-retain/n/#{old.id}")

      assert has_element?(view, "div#node-pane-#{old.id}-node-[phx-update=replace]")

      # The `{:nodes_pushed, ...}` half only proves that event path does not
      # touch the selection; the `toggle_pin` half is the `reload_dag/1`
      # assertion.
      Phoenix.PubSub.broadcast(
        Cadence.Server.PubSub,
        "project:#{project.id}",
        {:nodes_pushed, project.id, [newest.id]}
      )

      assert has_element?(view, "div#node-pane-#{old.id}-node-[phx-update=replace]")

      # A pin rebuilds the layout; it must keep the existing selection too.
      render_click(view, "toggle_pin", %{"id" => newest.id})

      assert has_element?(view, "div#node-pane-#{old.id}-node-[phx-update=replace]")
      assert Repo.get!(Node, newest.id).pinned
    end

    test "an out-of-window selected node links its history page and row", %{conn: conn} do
      put_config(:dag_max_nodes, 2)
      project = insert_project("dag-outside")
      nodes = insert_bare_nodes(project, 51)
      oldest = hd(nodes)

      {:ok, view, html} = live(conn, "/p/dag-outside/n/#{oldest.id}")

      assert html =~ "This commit is older than the rendered graph."

      href = "/p/dag-outside/history?page=2#node-#{oldest.id}"
      assert has_element?(view, "p.node-outside-graph a[href='#{href}']", "Find it in History")
    end

    test "an in-window selected node has no outside-graph note", %{conn: conn} do
      put_config(:dag_max_nodes, 2)
      project = insert_project("dag-inside")
      nodes = insert_bare_nodes(project, 51)
      newest = List.last(nodes)

      {:ok, view, html} = live(conn, "/p/dag-inside/n/#{newest.id}")

      refute html =~ "This commit is older than the rendered graph."
      refute has_element?(view, ".node-outside-graph")
    end
  end

  describe "import provenance" do
    setup do
      metadata = %{
        "import" => %{
          "source" => "git",
          "author" => "Ada Lovelace",
          "author_email" => "ada@example.com"
        }
      }

      project = insert_project("provenance")
      imported = insert_bare_node(project, %{message: "imported", session_metadata: metadata})
      local = insert_bare_node(project, %{message: "local"})

      %{project: project, imported: imported, local: local}
    end

    test "anonymous visitors see the author but never the email", %{
      conn: conn,
      project: project,
      imported: imported
    } do
      {:ok, _view, html} = live(conn, "/p/#{project.slug}/n/#{imported.id}")

      assert html =~ "Imported from git · Ada Lovelace"
      refute html =~ "ada@example.com"
    end

    test "the owner sees the author and the email", %{
      conn: conn,
      project: project,
      imported: imported
    } do
      owner = seed_user("provenance-owner@example.com", "Owner")
      insert_membership(project, owner, :owner)

      {:ok, _view, html} = live(signed_conn(conn, owner), "/p/#{project.slug}/n/#{imported.id}")

      assert html =~ "Imported from git · Ada Lovelace · ada@example.com"
    end

    test "a viewer member sees the author but not the email", %{
      conn: conn,
      project: project,
      imported: imported
    } do
      owner = seed_user("provenance-viewer-owner@example.com", "Owner")
      viewer = seed_user("provenance-viewer@example.com", "Viewer")
      insert_membership(project, owner, :owner)
      insert_membership(project, viewer, :viewer)

      {:ok, _view, html} = live(signed_conn(conn, viewer), "/p/#{project.slug}/n/#{imported.id}")

      assert html =~ "Imported from git · Ada Lovelace"
      refute html =~ "ada@example.com"
    end

    test "a non-imported node shows no provenance line", %{
      conn: conn,
      project: project,
      local: local
    } do
      {:ok, _view, html} = live(conn, "/p/#{project.slug}/n/#{local.id}")

      refute html =~ "Imported from git"
      refute html =~ "node-provenance"
    end
  end

  test "renders the empty state", %{conn: conn} do
    insert_project("empty")
    {:ok, view, html} = live(conn, "/p/empty")

    assert html =~ "No commits yet."
    assert has_element?(view, "div#node-pane-empty[phx-update=replace]")
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

    css = conn |> get("/assets/css/app.css") |> response(200)
    assert css =~ ".project-home"
    assert css =~ ".dag-rail"
  end

  defp put_config(key, value) do
    previous = Application.get_env(:cadence_server, key)

    Application.put_env(:cadence_server, key, value)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:cadence_server, key)
      else
        Application.put_env(:cadence_server, key, previous)
      end
    end)
  end

  # A row-only node is enough for layout/cap tests: no snapshot means the pane
  # renders the header and a quarantine notice, which is all these assert.
  defp insert_bare_node(project, attrs) do
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

  defp insert_bare_nodes(project, count) do
    base = ~U[2026-10-20 00:00:00Z]

    Enum.map(1..count, fn index ->
      insert_bare_node(project, %{
        message: "node #{index}",
        created_at: DateTime.add(base, index, :second)
      })
    end)
  end

  defp dag_node_count(html) do
    html
    |> String.split(~s(class="dag-node ))
    |> length()
    |> Kernel.-(1)
  end

  defp seed_user(email, name) do
    Ash.Seed.seed!(User, %{email: email, name: name})
  end

  defp actions_manifest do
    Jason.encode!(%{
      "actions" => [
        %{
          "name" => "run_analysis",
          "command" => "python actions/run.py",
          "description" => "Run the analysis",
          "expose" => true
        }
      ]
    })
  end

  defp open_secret_incident(project, node) do
    {:ok, incident} =
      Incidents.open(%{
        project_id: project.id,
        node_id: node.id,
        kind: :secret_detected,
        severity: :critical,
        title: "Secret detected",
        details: %{patterns: [:github_token]}
      })

    incident
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
