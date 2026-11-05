defmodule Cadence.ServerWeb.ReviewLiveTest do
  use Cadence.ServerWeb.ConnCase, async: false

  import Cadence.ServerFixtures
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Cadence.Server.{Incidents, Proposals, Repo}
  alias Cadence.Server.Accounts.User
  alias Cadence.Shared.Node

  setup do
    owner = seed_user("owner@example.com", "Olive Owner")
    project = project(owner.id, %{name: "Demo Project", slug: "demo"})
    membership(project, owner.id, :owner)

    parent_a =
      node_with_snapshot(project, %{"keep.txt" => "same", "app.txt" => "v1"}, %{
        message: "first parent"
      })

    parent_b = node_with_snapshot(project, %{"keep.txt" => "same"}, %{message: "second parent"})

    result =
      snapshot_tree(
        project,
        %{"keep.txt" => "same", "app.txt" => "v2", "new.txt" => "hi"},
        "meld result",
        [parent_a.git_commit_sha, parent_b.git_commit_sha]
      )

    proposal = meld_proposal(project, owner.id, [parent_a, parent_b], result)

    %{
      owner: owner,
      project: project,
      parent_a: parent_a,
      parent_b: parent_b,
      result: result,
      proposal: proposal
    }
  end

  describe "authorization" do
    test "anonymous visitors are redirected to the public project page", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/p/demo", flash: flash}}} =
               live(conn, "/p/demo/reviews")

      assert flash["error"] == "Only project members can review proposals."

      assert {:error, {:live_redirect, %{to: "/p/demo"}}} =
               live(conn, "/p/demo/reviews/#{Ecto.UUID.generate()}")
    end

    test "non-members are redirected with an error", %{
      conn: conn,
      proposal: proposal
    } do
      stranger = seed_user("stranger@example.com", "Sam Stranger")
      conn = signed_conn(conn, stranger)

      assert {:error, {:live_redirect, %{to: "/p/demo"}}} = live(conn, "/p/demo/reviews")

      assert {:error, {:live_redirect, %{to: "/p/demo"}}} =
               live(conn, "/p/demo/reviews/#{proposal.id}")
    end

    test "viewers may read the hub but see no decision controls", %{
      conn: conn,
      project: project,
      proposal: proposal
    } do
      viewer = seed_user("viewer@example.com", "Vic Viewer")
      membership(project, viewer.id, :viewer)

      {:ok, view, _html} = live(signed_conn(conn, viewer), "/p/demo/reviews")
      html = render_async(view)

      assert html =~ "Meld proposal"
      assert html =~ "pending"
      refute html =~ "Approve"

      {:ok, show, _html} = live(signed_conn(conn, viewer), "/p/demo/reviews/#{proposal.id}")
      show_html = render_async(show)

      assert show_html =~ "Meld proposal"
      assert show_html =~ "Olive Owner"
      refute show_html =~ "owner@example.com"
      refute show_html =~ "Approve"
      refute show_html =~ "Reject"
    end
  end

  describe "index" do
    test "lists proposals pending first and links the review and public surfaces", %{
      conn: conn,
      owner: owner,
      project: project
    } do
      [parent_a, parent_b] = load_parents(project)

      pending = meld_proposal(project, owner.id, [parent_a, parent_b], result_for(project, "a"))

      rejected = meld_proposal(project, owner.id, [parent_a, parent_b], result_for(project, "b"))
      {:ok, _rejected} = Proposals.reject(%{id: owner.id}, project.id, rejected.id)

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/demo/reviews")
      html = render_async(view)

      {pending_index, _} = :binary.match(html, "proposal-#{pending.id}")
      {rejected_index, _} = :binary.match(html, "proposal-#{rejected.id}")

      assert pending_index < rejected_index

      assert html =~ ~s(href="/p/demo/reviews/#{pending.id}")
      assert html =~ ~s(href="/proposals/#{pending.token}")
      assert html =~ ~s(href="/proposals/#{rejected.token}")
      assert html =~ "rejected"
      assert html =~ "2 parents"
      assert html =~ "just now"
    end

    test "renders an empty state and a not-found project", %{
      conn: conn,
      owner: owner,
      proposal: proposal
    } do
      other = project(owner.id, %{name: "Empty", slug: "empty"})
      membership(other, owner.id, :owner)

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/empty/reviews")
      html = render_async(view)

      assert html =~ "No proposals yet."
      refute html =~ proposal.token

      {:ok, missing_view, _html} = live(signed_conn(conn, owner), "/p/missing/reviews")
      assert render(missing_view) =~ "Project not found"
    end
  end

  describe "show" do
    test "owners approve a meld, attaching the node and showing the decision", %{
      conn: conn,
      owner: owner,
      proposal: proposal,
      result: result
    } do
      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/demo/reviews/#{proposal.id}")
      html = render_async(view)

      assert html =~ "Meld proposal"
      assert html =~ "first parent"
      assert html =~ "second parent"
      assert html =~ "new.txt"
      assert html =~ "Proposed by owner@example.com"
      assert html =~ "Approve"
      assert html =~ "Reject"

      view |> element("button", "Approve") |> render_click()
      decided = render_async(view)

      assert decided =~ "approved"
      assert decided =~ "Only pending proposals can be decided."
      refute decided =~ "Approve"

      assert [node] = Repo.all(from(n in Node, where: n.git_commit_sha == ^result.commit))
      assert node.pinned
      assert node.parents == proposal.parent_ids
      assert decided =~ "/p/demo/n/#{node.id}"

      assert Repo.get!(Cadence.Server.Proposal, proposal.id).reviewer_id == owner.id
    end

    test "a second approve click is idempotent and attaches no second node", %{
      conn: conn,
      owner: owner,
      proposal: proposal,
      result: result
    } do
      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/demo/reviews/#{proposal.id}")
      render_async(view)

      assert view |> element("button", "Approve") |> render_click() =~ "approved"
      assert render_click(view, "approve") =~ "approved"

      nodes = Repo.all(from(n in Node, where: n.git_commit_sha == ^result.commit))
      assert length(nodes) == 1
    end

    test "trusted members with the approver grant can reject", %{
      conn: conn,
      project: project,
      proposal: proposal
    } do
      approver = seed_user("approver@example.com", "Ada Approver")
      membership(project, approver.id, :trusted, %{approver: true})

      {:ok, view, _html} = live(signed_conn(conn, approver), "/p/demo/reviews/#{proposal.id}")
      html = render_async(view)
      assert html =~ "Approve"

      view |> element("button", "Reject") |> render_click()
      rejected = render_async(view)

      assert rejected =~ "rejected"
      assert Repo.get!(Cadence.Server.Proposal, proposal.id).reviewer_id == approver.id

      assert Repo.all(from(n in Node, where: n.project_id == ^project.id and n.pinned)) == []
    end

    test "a viewer cannot decide even with an injected event", %{
      conn: conn,
      project: project,
      proposal: proposal
    } do
      viewer = seed_user("viewer@example.com", "Vic Viewer")
      membership(project, viewer.id, :viewer)

      {:ok, view, _html} = live(signed_conn(conn, viewer), "/p/demo/reviews/#{proposal.id}")
      render_async(view)

      html = render_click(view, "approve")

      assert html =~ "Only the project owner or a granted approver may decide."
      assert Repo.get!(Cadence.Server.Proposal, proposal.id).status == :pending
      assert Repo.all(from(n in Node, where: n.git_commit_sha == ^proposal.meld_commit_sha)) == []
    end

    test "an isolated result is hidden and cannot be approved", %{
      conn: conn,
      owner: owner,
      project: project,
      proposal: proposal
    } do
      {:ok, _incident} =
        Incidents.open(%{
          project_id: project.id,
          proposal_id: proposal.id,
          kind: :secret_detected,
          severity: :critical,
          title: "Secret detected",
          details: %{patterns: [:github_token]}
        })

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/demo/reviews/#{proposal.id}")
      html = render_async(view)

      assert html =~ "Result hidden for review"
      refute html =~ "Approve"
      assert html =~ "Reject"

      refused = render_click(view, "approve")

      assert refused =~ "critical incident is open"
      assert Repo.get!(Cadence.Server.Proposal, proposal.id).status == :pending
    end

    test "an unverifiable result renders a warning and blocks approval", %{
      conn: conn,
      owner: owner,
      project: project,
      parent_a: parent_a,
      parent_b: parent_b
    } do
      proposal =
        meld_proposal(
          project,
          owner.id,
          [parent_a, parent_b],
          result_for(project, "mismatch"),
          %{result_tree_sha: String.duplicate("b", 40)}
        )

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/demo/reviews/#{proposal.id}")
      html = render_async(view)

      assert html =~ "could not be verified"
      assert html =~ "tree_mismatch"
      refute html =~ "Approve"

      refused = render_click(view, "approve")

      assert refused =~ "could not be verified"
      assert Repo.get!(Cadence.Server.Proposal, proposal.id).status == :pending

      # The failure opened a critical incident, so the reload shows quarantine.
      assert render_async(view) =~ "Result hidden for review"
    end

    test "a promotion renders its target and pins it on approval", %{
      conn: conn,
      owner: owner,
      project: project,
      parent_a: parent_a
    } do
      target = node_with_snapshot(project, %{"promote.txt" => "ready"}, %{message: "promote me"})
      proposal = promotion_proposal(project, owner.id, target)

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/demo/reviews/#{proposal.id}")
      html = render_async(view)

      assert html =~ "Promotion proposal"
      assert html =~ "View the target node"

      view |> element("button", "Approve") |> render_click()
      approved = render_async(view)

      assert approved =~ "approved"
      assert Repo.get!(Node, target.id).pinned
      refute Repo.get!(Node, parent_a.id).pinned
    end

    test "an unknown proposal renders a not-found state", %{conn: conn, owner: owner} do
      {:ok, view, _html} =
        live(signed_conn(conn, owner), "/p/demo/reviews/#{Ecto.UUID.generate()}")

      assert render_async(view) =~ "Proposal not found"
    end

    test "redacts secrets in parent commit messages", %{
      conn: conn,
      owner: owner,
      project: project,
      parent_b: parent_b
    } do
      tainted =
        node_with_snapshot(project, %{"tainted.txt" => "x"}, %{
          message: "deploy with token: ghp_abcdefghijklmnopqrstuvwxyz0123456789"
        })

      proposal =
        meld_proposal(project, owner.id, [tainted, parent_b], result_for(project, "redacted"))

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/demo/reviews/#{proposal.id}")
      html = render_async(view)

      refute html =~ "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
      assert html =~ "[REDACTED]"
    end

    test "a rejected proposal renders no decision controls and cannot be approved", %{
      conn: conn,
      owner: owner,
      project: project,
      proposal: proposal
    } do
      {:ok, _rejected} = Proposals.reject(%{id: owner.id}, project.id, proposal.id)

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/demo/reviews/#{proposal.id}")
      html = render_async(view)

      assert html =~ "rejected"
      assert html =~ "Only pending proposals can be decided."
      refute html =~ "Approve"
      refute html =~ "Reject"

      refused = render_click(view, "approve")

      assert refused =~ "This proposal has already been decided."
      assert Repo.get!(Cadence.Server.Proposal, proposal.id).status == :rejected
    end

    test "approval is blocked when the result cannot be reviewed", %{
      conn: conn,
      owner: owner,
      project: project,
      parent_a: parent_a,
      parent_b: parent_b
    } do
      # The result commit verifies, but the first parent is gone, so the diff —
      # everything the reviewer would see — is unavailable.
      proposal =
        meld_proposal(project, owner.id, [parent_a, parent_b], result_for(project, "blind"))

      Repo.delete!(parent_a)

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/demo/reviews/#{proposal.id}")
      html = render_async(view)

      assert html =~ "the result is not available yet"
      refute html =~ "Approve"
      assert html =~ "Reject"
    end
  end

  defp load_parents(project) do
    [parent_a, parent_b] = [
      node_with_snapshot(project, %{"a.txt" => "a"}, %{message: "a"}),
      node_with_snapshot(project, %{"b.txt" => "b"}, %{message: "b"})
    ]

    [parent_a, parent_b]
  end

  defp result_for(project, suffix) do
    snapshot_tree(project, %{"result-#{suffix}.txt" => suffix}, "result #{suffix}")
  end

  defp seed_user(email, name), do: Ash.Seed.seed!(User, %{email: email, name: name})

  defp signed_conn(conn, user) do
    {:ok, _token, claims} = AshAuthentication.Jwt.token_for_user(user)
    subject_name = AshAuthentication.Info.authentication_subject_name!(User)

    conn
    |> init_test_session(%{})
    |> put_session(to_string(subject_name), claims["jti"] <> ":" <> claims["sub"])
  end
end
