defmodule Cadence.ServerWeb.RunLiveTest do
  use Cadence.ServerWeb.ConnCase, async: false

  import Cadence.ServerFixtures
  import Phoenix.LiveViewTest

  alias Cadence.Server.{ActionRun, Repo}
  alias Cadence.Server.Accounts.User
  alias Cadence.Server.Actions.Runs
  alias Cadence.Server.FakeDocker

  @manifest Jason.encode!(%{
              "actions" => [
                %{
                  "name" => "run_analysis",
                  "command" => "python actions/run.py",
                  "description" => "Run the analysis",
                  "expose" => true
                }
              ]
            })
  @dockerfile "FROM alpine:3.20\nCMD [\"true\"]\n"

  setup do
    previous =
      Map.new([:actions_docker, :actions_enabled], fn key ->
        {key, Application.get_env(:cadence_server, key)}
      end)

    Application.put_env(:cadence_server, :actions_docker, FakeDocker)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:cadence_server, key)
        {key, value} -> Application.put_env(:cadence_server, key, value)
      end)
    end)

    FakeDocker.setup()

    volume_path = Application.fetch_env!(:cadence_server, :actions_volume_path)
    artifact_path = Application.fetch_env!(:cadence_server, :artifact_path)
    File.rm_rf!(volume_path)
    File.rm_rf!(artifact_path)

    owner = Ash.Seed.seed!(User, %{email: "run-owner@example.com", name: "Olive Owner"})
    viewer = Ash.Seed.seed!(User, %{email: "run-viewer@example.com", name: "Vic Viewer"})
    outsider = Ash.Seed.seed!(User, %{email: "run-outsider@example.com", name: "Sam Outsider"})

    project = project(owner.id, %{name: "Run Project", slug: "run-live"})
    membership(project, owner.id, :owner)
    membership(project, viewer.id, :viewer)

    node =
      node_with_snapshot(
        project,
        %{
          "Dockerfile" => @dockerfile,
          "actions/manifest.json" => @manifest,
          "actions/run.py" => "print('hi')\n"
        },
        %{message: "action node"}
      )

    %{
      project: project,
      owner: owner,
      viewer: viewer,
      outsider: outsider,
      node: node,
      volume_path: volume_path,
      artifact_path: artifact_path
    }
  end

  describe "project page run controls" do
    test "a manager sees Run controls and the run history link", %{
      conn: conn,
      project: project,
      owner: owner,
      node: node
    } do
      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/#{project.slug}")
      html = render_patch(view, "/p/#{project.slug}/n/#{node.id}")

      assert html =~ "run_analysis"
      assert html =~ "python actions/run.py"

      assert has_element?(
               view,
               "button[phx-click=run_action][phx-value-action=run_analysis]",
               "Run"
             )

      assert has_element?(view, "a[href='/p/#{project.slug}/runs']")
    end

    test "a viewer sees the action list but no Run controls", %{
      conn: conn,
      project: project,
      viewer: viewer,
      node: node
    } do
      {:ok, view, _html} = live(signed_conn(conn, viewer), "/p/#{project.slug}")
      html = render_patch(view, "/p/#{project.slug}/n/#{node.id}")

      assert html =~ "run_analysis"
      refute has_element?(view, "button[phx-click=run_action]")
      assert has_element?(view, "a[href='/p/#{project.slug}/runs']")
    end

    test "a forced run_action from a viewer is refused and writes nothing", %{
      conn: conn,
      project: project,
      viewer: viewer,
      node: node
    } do
      {:ok, view, _html} = live(signed_conn(conn, viewer), "/p/#{project.slug}")
      render_patch(view, "/p/#{project.slug}/n/#{node.id}")

      html = render_click(view, "run_action", %{"action" => "run_analysis"})

      assert html =~ "Only the project owner or a trusted member can run actions."
      assert Repo.aggregate(ActionRun, :count) == 0
    end

    test "clicking Run starts a run and navigates to its page", %{
      conn: conn,
      project: project,
      owner: owner,
      node: node
    } do
      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/#{project.slug}")
      render_patch(view, "/p/#{project.slug}/n/#{node.id}")

      assert {:error, {:live_redirect, %{to: to}}} =
               render_click(view, "run_action", %{"action" => "run_analysis"})

      assert to =~ "/p/#{project.slug}/runs/"

      [run] = Repo.all(ActionRun)
      assert run.project_id == project.id
      assert run.node_id == node.id
      assert run.action_name == "run_analysis"
      assert run.command == "python actions/run.py"

      assert eventually(fn ->
               Repo.get!(ActionRun, run.id).status
               |> ActionRun.terminal?()
             end)

      # The task clears the container id after removal; wait for that so a
      # later on_exit cannot race with the real Docker client.
      assert eventually(fn -> is_nil(Repo.get!(ActionRun, run.id).container_id) end)
    end

    test "an unknown action name is refused by the runner", %{
      conn: conn,
      project: project,
      owner: owner,
      node: node
    } do
      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/#{project.slug}")
      render_patch(view, "/p/#{project.slug}/n/#{node.id}")

      html = render_click(view, "run_action", %{"action" => "not_in_manifest"})

      assert html =~ "That action is no longer in the manifest."
      assert Repo.aggregate(ActionRun, :count) == 0
    end

    test "raw view cannot run a content-quarantined snapshot", %{
      conn: conn,
      project: project,
      owner: owner
    } do
      node =
        node_with_snapshot(
          project,
          %{
            "Dockerfile" => @dockerfile,
            "actions/manifest.json" => @manifest,
            ".env" => "TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789\n"
          },
          %{message: "quarantined action node"}
        )

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/#{project.slug}")
      render_patch(view, "/p/#{project.slug}/n/#{node.id}")

      # Raw view forces the rendered quarantine answer to :ok, so the panel and
      # its Run control reappear. The event must still re-derive the real scan.
      render_click(view, "toggle_raw")

      html = render_click(view, "run_action", %{"action" => "run_analysis"})

      assert html =~ "This snapshot is quarantined and cannot run actions."
      assert Repo.aggregate(ActionRun, :count) == 0
    end
  end

  describe "run list" do
    test "members see runs linked to their node and detail page", %{
      conn: conn,
      project: project,
      owner: owner,
      viewer: viewer,
      node: node
    } do
      run = finished_run(project, owner, node)

      {:ok, view, _html} = live(signed_conn(conn, viewer), "/p/#{project.slug}/runs")
      html = render_async(view)

      assert html =~ "run_analysis"
      assert html =~ "succeeded"
      assert has_element?(view, "a[href='/p/#{project.slug}/runs/#{run.id}']")
      assert has_element?(view, "a[href='/p/#{project.slug}/n/#{node.id}']")
    end

    test "anonymous and non-member visitors are redirected", %{
      conn: conn,
      project: project,
      outsider: outsider
    } do
      assert {:error, {:live_redirect, %{to: "/p/run-live", flash: flash}}} =
               live(conn, "/p/run-live/runs")

      assert flash["error"] == "Only project members can see action runs."

      assert {:error, {:live_redirect, %{to: "/p/run-live"}}} =
               live(signed_conn(conn, outsider), "/p/run-live/runs")

      assert project.slug == "run-live"
    end

    test "an unknown project renders the not-found view", %{conn: conn, owner: owner} do
      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/missing/runs")
      assert render(view) =~ "Project not found"
    end

    test "the list refreshes when a run changes", %{
      conn: conn,
      project: project,
      owner: owner,
      viewer: viewer,
      node: node
    } do
      {:ok, run} = Runs.prepare(%{id: owner.id}, project.id, node.id, "run_analysis")

      {:ok, view, _html} = live(signed_conn(conn, viewer), "/p/#{project.slug}/runs")
      assert render_async(view) =~ "queued"

      assert {:ok, _finished} = Runs.execute(run)

      assert render_async(view) =~ "succeeded"
    end

    test "a disabled deployment hides the link and redirects run pages", %{
      conn: conn,
      project: project,
      owner: owner
    } do
      Application.put_env(:cadence_server, :actions_enabled, false)

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/#{project.slug}")
      refute has_element?(view, "a[href='/p/#{project.slug}/runs']")

      assert {:error, {:live_redirect, %{to: "/p/run-live", flash: flash}}} =
               live(signed_conn(conn, owner), "/p/#{project.slug}/runs")

      assert flash["error"] == "Action runs are disabled for this deployment."

      assert {:error, {:live_redirect, %{to: "/p/run-live"}}} =
               live(signed_conn(conn, owner), "/p/#{project.slug}/runs/#{Ecto.UUID.generate()}")
    end
  end

  describe "run list paging" do
    test "pages runs 50 at a time with newer/older links", %{
      conn: conn,
      project: project,
      owner: owner,
      viewer: viewer,
      node: node
    } do
      runs = insert_runs(project, node, owner, 51)
      newest = hd(runs)
      oldest = List.last(runs)

      {:ok, view, _html} = live(signed_conn(conn, viewer), "/p/#{project.slug}/runs")
      html = render_async(view)

      assert html =~ "Page 1"
      assert has_element?(view, "#run-#{newest.id}")
      refute has_element?(view, "#run-#{oldest.id}")
      assert has_element?(view, "a[href='/p/run-live/runs?page=2']")
      refute has_element?(view, "a[href='/p/run-live/runs?page=0']")

      {:ok, view, _html} =
        live(signed_conn(conn, viewer), "/p/#{project.slug}/runs?page=2")

      html = render_async(view)

      assert html =~ "Page 2"
      assert has_element?(view, "#run-#{oldest.id}")
      refute has_element?(view, "#run-#{newest.id}")
      assert has_element?(view, "a[href='/p/run-live/runs?page=1']")
      refute has_element?(view, "a[href='/p/run-live/runs?page=3']")
    end

    test "junk page params fall back to the first page", %{
      conn: conn,
      project: project,
      owner: owner,
      viewer: viewer,
      node: node
    } do
      newest = project |> insert_runs(node, owner, 51) |> hd()

      for query <- ["page=abc", "page=0", "page=-3"] do
        {:ok, view, _html} =
          live(signed_conn(conn, viewer), "/p/#{project.slug}/runs?#{query}")

        render_async(view)

        assert has_element?(view, "#run-#{newest.id}")
        assert has_element?(view, "a[href='/p/run-live/runs?page=2']")
      end
    end

    test "an out-of-range page is empty and links to the newest runs", %{
      conn: conn,
      project: project,
      owner: owner,
      viewer: viewer,
      node: node
    } do
      newest = project |> insert_runs(node, owner, 3) |> hd()

      {:ok, view, _html} =
        live(signed_conn(conn, viewer), "/p/#{project.slug}/runs?page=99")

      render_async(view)

      assert render(view) =~ "No runs on this page."
      refute has_element?(view, ".run-list")
      refute has_element?(view, "#run-#{newest.id}")
      assert has_element?(view, "a[href='/p/run-live/runs?page=1']")
    end

    test "a live event reloads the current page, not the first", %{
      conn: conn,
      project: project,
      owner: owner,
      viewer: viewer,
      node: node
    } do
      runs = insert_runs(project, node, owner, 51)
      newest = hd(runs)
      oldest = List.last(runs)

      {:ok, view, _html} =
        live(signed_conn(conn, viewer), "/p/#{project.slug}/runs?page=2")

      render_async(view)

      # A broadcast alone would leave the page unchanged, so mutate the row:
      # only a reload at the current offset picks up the new status without
      # moving to page 1.
      Repo.get!(ActionRun, oldest.id)
      |> Ecto.Changeset.change(status: :failed)
      |> Repo.update!()

      Phoenix.PubSub.broadcast(
        Cadence.Server.PubSub,
        "project:#{project.id}",
        {:action_run_updated, project.id, oldest.id, :failed}
      )

      html = render_async(view)

      assert has_element?(view, "#run-#{oldest.id}", "failed")
      assert html =~ "Page 2"
      refute has_element?(view, "#run-#{newest.id}")
    end
  end

  describe "run detail" do
    test "shows status, provenance, escaped output, and artifacts", %{
      conn: conn,
      project: project,
      owner: owner,
      viewer: viewer,
      node: node
    } do
      run =
        finished_run(project, owner, node,
          logs: {:ok, "\e[31mhello\e[0m <script>alert(1)</script>\n"},
          artifact: {"report.txt", "ok\n"}
        )

      {:ok, view, _html} = live(signed_conn(conn, viewer), "/p/#{project.slug}/runs/#{run.id}")
      html = render_async(view)

      assert html =~ "run_analysis"
      assert html =~ "succeeded"
      assert html =~ "python actions/run.py"
      assert html =~ "hello"
      refute html =~ "\e[31m"
      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
      assert html =~ "report.txt"

      assert has_element?(
               view,
               "a[href='/p/#{project.slug}/runs/#{run.id}/artifacts/report.txt']"
             )

      assert has_element?(view, "a[href='/p/#{project.slug}/n/#{node.id}']")
    end

    test "a queued run explains that it is waiting for a slot", %{
      conn: conn,
      project: project,
      owner: owner,
      viewer: viewer,
      node: node
    } do
      {:ok, run} = Runs.prepare(%{id: owner.id}, project.id, node.id, "run_analysis")

      {:ok, view, _html} = live(signed_conn(conn, viewer), "/p/#{project.slug}/runs/#{run.id}")
      html = render_async(view)

      assert html =~ "queued"
      assert html =~ "Queued: the run starts when this project has a free action slot."
      refute html =~ "The action is running."
    end

    test "shows a mapped failure reason", %{
      conn: conn,
      project: project,
      owner: owner,
      viewer: viewer,
      node: node
    } do
      run = finished_run(project, owner, node, wait: {:error, :timeout})

      {:ok, view, _html} = live(signed_conn(conn, viewer), "/p/#{project.slug}/runs/#{run.id}")
      html = render_async(view)

      assert html =~ "timed out"
      assert html =~ "The action timed out and was stopped."
    end

    test "an unknown run is not found", %{conn: conn, project: project, viewer: viewer} do
      {:ok, view, _html} =
        live(signed_conn(conn, viewer), "/p/#{project.slug}/runs/#{Ecto.UUID.generate()}")

      assert render_async(view) =~ "This run was not found in this project."
    end

    test "refreshes when its own run changes", %{
      conn: conn,
      project: project,
      owner: owner,
      viewer: viewer,
      node: node
    } do
      {:ok, run} = Runs.prepare(%{id: owner.id}, project.id, node.id, "run_analysis")

      {:ok, view, _html} = live(signed_conn(conn, viewer), "/p/#{project.slug}/runs/#{run.id}")
      assert render_async(view) =~ "queued"

      assert {:ok, _finished} = Runs.execute(run)

      assert render_async(view) =~ "succeeded"
    end

    test "ignores a status event for another run", %{
      conn: conn,
      project: project,
      owner: owner,
      viewer: viewer,
      node: node
    } do
      run = finished_run(project, owner, node)

      {:ok, view, _html} = live(signed_conn(conn, viewer), "/p/#{project.slug}/runs/#{run.id}")
      assert render_async(view) =~ "succeeded"

      Phoenix.PubSub.broadcast(
        Cadence.Server.PubSub,
        "project:#{project.id}",
        {:action_run_updated, project.id, Ecto.UUID.generate(), :failed}
      )

      html = render(view)
      assert html =~ "succeeded"
      refute html =~ "status-rejected"
    end

    test "a run from another project is not found", %{
      conn: conn,
      project: project,
      owner: owner,
      viewer: viewer
    } do
      other = project(owner.id, %{name: "Other", slug: "run-other"})
      membership(other, owner.id, :owner)
      other_node = node_with_snapshot(other, %{"actions/manifest.json" => @manifest})

      {:ok, other_run} =
        Runs.prepare(%{id: owner.id}, other.id, other_node.id, "run_analysis")

      {:ok, view, _html} =
        live(signed_conn(conn, viewer), "/p/#{project.slug}/runs/#{other_run.id}")

      assert render_async(view) =~ "This run was not found in this project."
    end
  end

  describe "artifact downloads" do
    test "a member downloads a collected artifact as an attachment", %{
      conn: conn,
      project: project,
      owner: owner,
      viewer: viewer,
      node: node
    } do
      run = finished_run(project, owner, node, artifact: {"report.txt", "ok\n"})

      response =
        get(
          signed_conn(conn, viewer),
          "/p/#{project.slug}/runs/#{run.id}/artifacts/report.txt"
        )

      assert response.status == 200
      assert response.resp_body == "ok\n"
      assert get_resp_header(response, "content-disposition") == ["attachment"]
      assert get_resp_header(response, "content-type") == ["application/octet-stream"]
      assert get_resp_header(response, "cache-control") == ["private, no-store"]
    end

    test "nested artifact paths with spaces are linked and downloadable", %{
      conn: conn,
      project: project,
      owner: owner,
      viewer: viewer,
      node: node
    } do
      run = finished_run(project, owner, node, artifact: {"nested/report 1.txt", "ok\n"})

      {:ok, view, _html} = live(signed_conn(conn, viewer), "/p/#{project.slug}/runs/#{run.id}")
      html = render_async(view)

      assert html =~ "nested/report 1.txt"

      assert has_element?(
               view,
               "a[href='/p/#{project.slug}/runs/#{run.id}/artifacts/nested/report%201.txt']"
             )

      response =
        get(
          signed_conn(conn, viewer),
          "/p/#{project.slug}/runs/#{run.id}/artifacts/nested/report%201.txt"
        )

      assert response.status == 200
      assert response.resp_body == "ok\n"
    end

    test "a disabled deployment refuses downloads", %{
      conn: conn,
      project: project,
      owner: owner,
      viewer: viewer,
      node: node
    } do
      run = finished_run(project, owner, node, artifact: {"report.txt", "ok\n"})

      Application.put_env(:cadence_server, :actions_enabled, false)

      assert get(
               signed_conn(conn, viewer),
               "/p/#{project.slug}/runs/#{run.id}/artifacts/report.txt"
             ).status == 404
    end

    test "outsiders, unknown runs, and unknown artifacts are 404", %{
      conn: conn,
      project: project,
      owner: owner,
      viewer: viewer,
      outsider: outsider,
      node: node
    } do
      run = finished_run(project, owner, node, artifact: {"report.txt", "ok\n"})
      path = "/p/#{project.slug}/runs/#{run.id}/artifacts/report.txt"

      assert get(conn, path).status == 404
      assert get(signed_conn(conn, outsider), path).status == 404

      assert get(
               signed_conn(conn, viewer),
               "/p/#{project.slug}/runs/#{Ecto.UUID.generate()}/artifacts/report.txt"
             ).status == 404

      assert get(signed_conn(conn, viewer), path <> ".nope").status == 404
    end

    test "path traversal cannot escape the recorded artifacts", %{
      conn: conn,
      project: project,
      owner: owner,
      viewer: viewer,
      node: node
    } do
      run = finished_run(project, owner, node, artifact: {"report.txt", "ok\n"})

      response =
        get(
          signed_conn(conn, viewer),
          "/p/#{project.slug}/runs/#{run.id}/artifacts/..%2Foutput.log"
        )

      assert response.status == 404
    end
  end

  describe "artifact paging" do
    test "pages collected artifacts 100 at a time", %{
      conn: conn,
      project: project,
      owner: owner,
      viewer: viewer,
      node: node
    } do
      run = finished_run(project, owner, node, artifact_count: 150)
      path = "/p/#{project.slug}/runs/#{run.id}"

      {:ok, view, _html} = live(signed_conn(conn, viewer), path)
      html = render_async(view)

      assert html =~ "file-001.txt"
      assert html =~ "file-100.txt"
      refute html =~ "file-101.txt"
      assert html =~ "Page 1 of 2"
      assert has_element?(view, "a[href='#{path}?artifacts_page=2']")
      refute has_element?(view, "a[href='#{path}?artifacts_page=0']")

      {:ok, view, _html} =
        live(signed_conn(conn, viewer), path <> "?artifacts_page=2")

      html = render_async(view)

      assert html =~ "file-101.txt"
      assert html =~ "file-150.txt"
      refute html =~ "file-001.txt"
      assert html =~ "Page 2 of 2"
      assert has_element?(view, "a[href='#{path}?artifacts_page=1']")
      refute has_element?(view, "a[href='#{path}?artifacts_page=3']")

      # The whole set is in memory, so an out-of-range page clamps to the last.
      {:ok, view, _html} =
        live(signed_conn(conn, viewer), path <> "?artifacts_page=99")

      html = render_async(view)

      assert html =~ "file-150.txt"
      assert html =~ "Page 2 of 2"
    end

    test "a live refresh keeps the artifact page", %{
      conn: conn,
      project: project,
      owner: owner,
      viewer: viewer,
      node: node
    } do
      run = finished_run(project, owner, node, artifact_count: 150)
      path = "/p/#{project.slug}/runs/#{run.id}?artifacts_page=2"

      {:ok, view, _html} = live(signed_conn(conn, viewer), path)
      assert render_async(view) =~ "file-101.txt"

      # Mutate the row so the reload's effect is observable, not just the page
      # number it happened to keep.
      Repo.get!(ActionRun, run.id)
      |> Ecto.Changeset.change(status: :failed)
      |> Repo.update!()

      Phoenix.PubSub.broadcast(
        Cadence.Server.PubSub,
        "project:#{project.id}",
        {:action_run_updated, project.id, run.id, :failed}
      )

      html = render_async(view)

      assert has_element?(view, ".run-detail-heading .status-rejected", "failed")
      assert html =~ "Page 2 of 2"
      assert html =~ "file-101.txt"
      refute html =~ "file-001.txt"
    end
  end

  ## Helpers

  defp finished_run(project, owner, node, opts \\ []) do
    {:ok, run} = Runs.prepare(%{id: owner.id}, project.id, node.id, "run_analysis")

    out_dir =
      Path.join([
        Application.fetch_env!(:cadence_server, :actions_volume_path),
        run.id,
        "out"
      ])

    File.mkdir_p!(out_dir)
    artifact = Keyword.get(opts, :artifact)
    artifact_count = Keyword.get(opts, :artifact_count, 0)

    FakeDocker.script(
      Map.merge(
        %{
          wait: Keyword.get(opts, :wait, {:ok, 0}),
          logs: Keyword.get(opts, :logs, {:ok, "action output\n"}),
          on_wait: fn ->
            case artifact do
              {name, content} ->
                full = Path.join(out_dir, name)
                File.mkdir_p!(Path.dirname(full))
                File.write!(full, content)

              nil ->
                :ok
            end

            write_artifacts(out_dir, artifact_count)
          end
        },
        Keyword.get(opts, :script, %{})
      )
    )

    {:ok, finished} = Runs.execute(run)
    finished
  end

  defp write_artifacts(_out_dir, 0), do: :ok

  defp write_artifacts(out_dir, count) do
    for index <- 1..count do
      name = "file-#{String.pad_leading(Integer.to_string(index), 3, "0")}.txt"
      File.write!(Path.join(out_dir, name), "x")
    end

    :ok
  end

  # Queued rows with explicit, strictly decreasing timestamps, newest first, so
  # page order is deterministic without depending on insert speed.
  defp insert_runs(project, node, user, count) do
    base = DateTime.utc_now()

    for step <- 1..count do
      %ActionRun{}
      |> ActionRun.changeset(%{
        project_id: project.id,
        node_id: node.id,
        user_id: user.id,
        action_name: "run_analysis",
        command: "python actions/run.py"
      })
      |> Ecto.Changeset.put_change(:created_at, DateTime.add(base, -step, :second))
      |> Repo.insert!()
    end
  end

  defp signed_conn(conn, user) do
    {:ok, _token, claims} = AshAuthentication.Jwt.token_for_user(user)
    subject_name = AshAuthentication.Info.authentication_subject_name!(User)

    conn
    |> init_test_session(%{})
    |> put_session(to_string(subject_name), claims["jti"] <> ":" <> claims["sub"])
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end
end
