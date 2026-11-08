defmodule Cadence.ServerWeb.ReviewLiveTest do
  use Cadence.ServerWeb.ConnCase, async: false

  import Cadence.ServerFixtures
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Cadence.Server.{Incidents, ProposalView, Proposals, Repo}
  alias Cadence.Server.Accounts.User
  alias Cadence.ServerWeb.ReviewLive.Show
  alias Cadence.Shared.{Membership, Node}

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

      assert html =~ "The meld result is not available yet."
      assert html =~ "missing_parent"
      refute html =~ "Approve"
      assert html =~ "Reject"

      refused = render_click(view, "approve")

      assert refused =~ "could not be verified"
      assert Repo.get!(Cadence.Server.Proposal, proposal.id).status == :pending
    end
  end

  describe "incidents" do
    test "lists open incidents critical first and renders only the redacted summary", %{
      conn: conn,
      owner: owner,
      project: project
    } do
      node = node_with_snapshot(project, %{"scan.txt" => "scan me"}, %{message: "scan node"})

      {:ok, high} =
        Incidents.open(%{
          project_id: project.id,
          node_id: node.id,
          kind: :scan_incomplete,
          severity: :high,
          title: "Snapshot scan incomplete",
          details: %{reason: :too_many_files}
        })

      {:ok, critical} =
        Incidents.open(%{
          project_id: project.id,
          node_id: node.id,
          kind: :secret_detected,
          severity: :critical,
          title: "Secret detected in snapshot",
          details: %{patterns: [:github_token], note: "SHOULD_NOT_RENDER"}
        })

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/demo/reviews")
      html = render_async(view)

      assert html =~ "Open incidents"
      assert html =~ "Secret detected in snapshot"
      assert html =~ "secret detected"
      assert html =~ "Snapshot scan incomplete"
      assert html =~ "scan incomplete"

      {critical_index, _} = :binary.match(html, "incident-#{critical.id}")
      {high_index, _} = :binary.match(html, "incident-#{high.id}")
      assert critical_index < high_index

      assert html =~ "<dt>patterns</dt>"
      assert html =~ "github_token"
      assert html =~ "<dt>reason</dt>"
      assert html =~ "too_many_files"
      assert html =~ ~s(href="/p/demo/n/#{node.id}")
      refute html =~ "SHOULD_NOT_RENDER"
    end

    test "a granted approver resolves a node incident by acknowledgment", %{
      conn: conn,
      project: project
    } do
      approver = seed_user("approver@example.com", "Ada Approver")
      membership(project, approver.id, :trusted, %{approver: true})
      node = node_with_snapshot(project, %{"scan.txt" => "scan me"}, %{message: "scan node"})
      incident = open_node_incident(project, node)

      {:ok, view, _html} = live(signed_conn(conn, approver), "/p/demo/reviews")
      html = render_async(view)
      assert html =~ "incident-#{incident.id}"
      assert html =~ "Acknowledge"

      clicked = render_click(view, "resolve_incident", %{"id" => incident.id})
      assert clicked =~ "Incident resolved."

      html = render_async(view)
      refute html =~ "incident-#{incident.id}"

      stored = Repo.get!(Cadence.Server.Incident, incident.id)
      assert stored.status == :resolved
      assert stored.resolved_by == approver.id
    end

    test "a risky proposal incident stays open and points at reject-and-re-propose", %{
      conn: conn,
      owner: owner,
      project: project,
      parent_a: parent_a,
      parent_b: parent_b
    } do
      leaky =
        snapshot_tree(
          project,
          %{"leak.txt" => "token = ghp_abcdefghijklmnopqrstuvwxyz0123456789"},
          "leaky result"
        )

      proposal = meld_proposal(project, owner.id, [parent_a, parent_b], leaky)

      {:ok, incident} =
        Incidents.open(%{
          project_id: project.id,
          proposal_id: proposal.id,
          kind: :secret_detected,
          severity: :critical,
          title: "Secret detected in meld result",
          details: %{patterns: [:github_token]}
        })

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/demo/reviews")
      assert render_async(view) =~ "Resolve"

      clicked = render_click(view, "resolve_incident", %{"id" => incident.id})
      assert clicked =~ "still contains sensitive content"
      assert clicked =~ "reject and re-propose"

      assert render_async(view) =~ "incident-#{incident.id}"
      assert Repo.get!(Cadence.Server.Incident, incident.id).status == :open
    end

    test "a clean proposal result resolves its incident", %{
      conn: conn,
      owner: owner,
      proposal: proposal
    } do
      {:ok, incident} =
        Incidents.open(%{
          project_id: proposal.project_id,
          proposal_id: proposal.id,
          kind: :secret_detected,
          severity: :critical,
          title: "Secret detected in meld result",
          details: %{patterns: [:github_token]}
        })

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/demo/reviews")
      render_async(view)

      render_click(view, "resolve_incident", %{"id" => incident.id})
      html = render_async(view)

      refute html =~ "incident-#{incident.id}"
      stored = Repo.get!(Cadence.Server.Incident, incident.id)
      assert stored.status == :resolved
      assert stored.resolved_by == owner.id
    end

    test "a project-scoped incident resolves by acknowledgment", %{
      conn: conn,
      owner: owner,
      project: project
    } do
      {:ok, incident} =
        Incidents.open(%{
          project_id: project.id,
          kind: :meld_failed,
          severity: :high,
          title: "Meld agent failed",
          details: %{reason: :timeout}
        })

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/demo/reviews")
      assert render_async(view) =~ "Project-wide"

      render_click(view, "resolve_incident", %{"id" => incident.id})
      html = render_async(view)

      refute html =~ "incident-#{incident.id}"
      assert Repo.get!(Cadence.Server.Incident, incident.id).status == :resolved
    end

    test "viewers see the panel but cannot resolve, even with an injected event", %{
      conn: conn,
      project: project
    } do
      viewer = seed_user("viewer@example.com", "Vic Viewer")
      membership(project, viewer.id, :viewer)
      node = node_with_snapshot(project, %{"scan.txt" => "scan me"}, %{message: "scan node"})
      incident = open_node_incident(project, node)

      {:ok, view, _html} = live(signed_conn(conn, viewer), "/p/demo/reviews")
      html = render_async(view)

      assert html =~ "Secret detected in snapshot"
      refute html =~ "Acknowledge"
      refute html =~ ~s(phx-click="resolve_incident")

      denied = render_click(view, "resolve_incident", %{"id" => incident.id})
      assert denied =~ "Only the project owner or a granted approver may resolve incidents."
      refute denied =~ ~s(phx-click="resolve_incident")

      assert Repo.get!(Cadence.Server.Incident, incident.id).status == :open
    end

    test "a trusted member without the approver grant cannot resolve", %{
      conn: conn,
      project: project
    } do
      trusted = seed_user("trusted@example.com", "Tess Trusted")
      membership(project, trusted.id, :trusted)
      node = node_with_snapshot(project, %{"scan.txt" => "scan me"}, %{message: "scan node"})
      incident = open_node_incident(project, node)

      {:ok, view, _html} = live(signed_conn(conn, trusted), "/p/demo/reviews")
      html = render_async(view)

      assert html =~ "Secret detected in snapshot"
      refute html =~ ~s(phx-click="resolve_incident")

      denied = render_click(view, "resolve_incident", %{"id" => incident.id})
      assert denied =~ "Only the project owner or a granted approver may resolve incidents."
      assert Repo.get!(Cadence.Server.Incident, incident.id).status == :open
    end

    test "an unscannable proposal result keeps its incident open without crashing", %{
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
          result_for(project, "gone"),
          %{meld_commit_sha: String.duplicate("0", 40)}
        )

      incident = open_proposal_incident(proposal)

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/demo/reviews")
      render_async(view)

      clicked = render_click(view, "resolve_incident", %{"id" => incident.id})
      assert clicked =~ "could not be scanned, so the incident stays open"

      assert render_async(view) =~ "incident-#{incident.id}"
      assert Repo.get!(Cadence.Server.Incident, incident.id).status == :open
    end

    test "a sensitive path keeps a proposal incident open even when its content is clean", %{
      conn: conn,
      owner: owner,
      project: project,
      parent_a: parent_a,
      parent_b: parent_b
    } do
      hidden =
        snapshot_tree(
          project,
          %{"keep.txt" => "keep", ".env" => "SAFE=1"},
          "hidden path result"
        )

      proposal = meld_proposal(project, owner.id, [parent_a, parent_b], hidden)
      incident = open_proposal_incident(proposal)

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/demo/reviews")
      render_async(view)

      clicked = render_click(view, "resolve_incident", %{"id" => incident.id})
      assert clicked =~ "still contains sensitive content"

      assert Repo.get!(Cadence.Server.Incident, incident.id).status == :open
    end

    test "an approval-integrity incident cannot be resolved while the tree mismatches", %{
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

      {:ok, incident} =
        Incidents.open(%{
          project_id: project.id,
          proposal_id: proposal.id,
          kind: :scan_incomplete,
          severity: :critical,
          title: "Meld result could not be verified",
          details: %{stage: :approval_integrity, reason: :tree_mismatch}
        })

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/demo/reviews")
      render_async(view)

      clicked = render_click(view, "resolve_incident", %{"id" => incident.id})
      assert clicked =~ "no longer verifiable"

      assert Repo.get!(Cadence.Server.Incident, incident.id).status == :open
    end

    test "a promotion proposal incident resolves without a store scan", %{
      conn: conn,
      owner: owner,
      project: project
    } do
      target = node_with_snapshot(project, %{"promote.txt" => "ready"}, %{message: "promote me"})
      proposal = promotion_proposal(project, owner.id, target)

      {:ok, incident} =
        Incidents.open(%{
          project_id: project.id,
          proposal_id: proposal.id,
          kind: :scan_incomplete,
          severity: :critical,
          title: "Promotion needs review",
          details: %{reason: :tree_mismatch}
        })

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/demo/reviews")
      render_async(view)

      render_click(view, "resolve_incident", %{"id" => incident.id})

      assert Repo.get!(Cadence.Server.Incident, incident.id).status == :resolved
    end

    test "unknown and cross-project incident ids are refused", %{
      conn: conn,
      owner: owner
    } do
      other = project(owner.id, %{name: "Other", slug: "other"})
      membership(other, owner.id, :owner)
      other_node = node_with_snapshot(other, %{"other.txt" => "other"}, %{message: "other"})
      other_incident = open_node_incident(other, other_node)

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/demo/reviews")
      render_async(view)

      cross = render_click(view, "resolve_incident", %{"id" => other_incident.id})
      assert cross =~ "This incident no longer exists."
      assert Repo.get!(Cadence.Server.Incident, other_incident.id).status == :open

      unknown = render_click(view, "resolve_incident", %{"id" => Ecto.UUID.generate()})
      assert unknown =~ "This incident no longer exists."
      assert Repo.get!(Cadence.Server.Incident, other_incident.id).status == :open
    end
  end

  describe "incident relevance" do
    test "an incident before the first load always forces a reload" do
      assert Show.incident_relevant?("proposal", [], false, nil, "node")
      assert Show.incident_relevant?("proposal", [], false, "proposal", nil)
    end

    test "after a load only this proposal or a decision node is relevant" do
      assert Show.incident_relevant?("proposal", ["node"], true, nil, "node")
      assert Show.incident_relevant?("proposal", ["other"], true, "proposal", nil)
      refute Show.incident_relevant?("proposal", ["other"], true, nil, "node")
      refute Show.incident_relevant?("proposal", [], true, "another", "node")
    end
  end

  describe "styling" do
    test "incidents sit above the queue with distinct severity and full details", %{
      conn: conn,
      owner: owner,
      project: project,
      proposal: proposal
    } do
      node = node_with_snapshot(project, %{"scan.txt" => "scan me"}, %{message: "scan node"})

      long_reason =
        "the scanner stopped after the configured cap and could not inspect the remaining files"

      {:ok, high} =
        Incidents.open(%{
          project_id: project.id,
          node_id: node.id,
          kind: :scan_incomplete,
          severity: :high,
          title: "Snapshot scan incomplete",
          details: %{reason: long_reason}
        })

      {:ok, critical} =
        Incidents.open(%{
          project_id: project.id,
          proposal_id: proposal.id,
          kind: :secret_detected,
          severity: :critical,
          title: "Secret detected in meld result",
          details: %{
            patterns: [:github_token],
            sensitive_paths: 2,
            note: "SHOULD_NOT_RENDER"
          }
        })

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/demo/reviews")
      html = render_async(view)

      {panel_index, _} = :binary.match(html, ~s(id="incidents-panel"))
      {queue_index, _} = :binary.match(html, "proposal-#{proposal.id}")
      assert panel_index < queue_index

      # The live region must cover the critical-count line, not only the count.
      assert has_element?(
               view,
               ~s([aria-live="polite"] .critical-count),
               "1 critical incident blocking approval."
             )

      {critical_index, _} = :binary.match(html, "incident-#{critical.id}")
      {high_index, _} = :binary.match(html, "incident-#{high.id}")
      assert critical_index < high_index

      assert html =~ ~s(class="incident-row severity-critical")
      assert html =~ ~s(class="incident-row severity-high")
      assert html =~ "badge severity-badge severity-critical"
      assert html =~ "badge severity-badge severity-high"
      assert html =~ "1 critical incident blocking approval."
      assert html =~ "2 sensitive paths hidden"

      # The full reason is rendered, not the old 60-character summary.
      assert html =~ long_reason
      refute html =~ String.slice(long_reason, 0, 60) <> "…"
      refute html =~ "SHOULD_NOT_RENDER"

      assert html =~ ~s(class="admin-button button-primary")
      assert html =~ ~s(class="admin-button button-warning")
      assert html =~ "Re-scans the stored result"
      assert html =~ "Acknowledges the alert only"
      assert html =~ "badge status-badge status-pending"
      assert html =~ ~s(class="public-link")
    end

    test "the queue and decision controls use the shared badge and button classes", %{
      conn: conn,
      owner: owner,
      proposal: proposal
    } do
      {:ok, index, _html} = live(signed_conn(conn, owner), "/p/demo/reviews")
      index_html = render_async(index)

      assert index_html =~ ~s(class="proposal-list")
      assert index_html =~ ~s(class="proposal-row")
      assert index_html =~ "badge status-badge status-pending"
      assert index_html =~ ~s(class="public-link")

      {:ok, show, _html} = live(signed_conn(conn, owner), "/p/demo/reviews/#{proposal.id}")
      show_html = render_async(show)

      assert show_html =~ "badge status-badge status-pending"
      assert show_html =~ ~s(class="admin-button button-primary")
      assert show_html =~ ~s(class="admin-button button-danger")
      assert show_html =~ "file-status file-status-added"
      assert show_html =~ "file-status file-status-modified"
      refute show_html =~ "file-status file-status-deleted"
    end
  end

  describe "freshness" do
    test "index shows an incident opened after mount", %{
      conn: conn,
      owner: owner,
      project: project
    } do
      node = node_with_snapshot(project, %{"scan.txt" => "scan me"}, %{message: "scan node"})

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/demo/reviews")
      assert render_async(view) =~ "No open incidents."

      incident = open_node_incident(project, node)

      html = render_async(view)
      assert html =~ "incident-#{incident.id}"
      assert html =~ "Secret detected in snapshot"
    end

    test "index drops an incident resolved elsewhere", %{
      conn: conn,
      owner: owner,
      project: project
    } do
      node = node_with_snapshot(project, %{"scan.txt" => "scan me"}, %{message: "scan node"})
      incident = open_node_incident(project, node)

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/demo/reviews")
      assert render_async(view) =~ "incident-#{incident.id}"

      assert {:ok, _resolved} = Incidents.resolve(%{id: owner.id}, project.id, incident.id)

      html = render_async(view)
      refute html =~ "incident-#{incident.id}"
      assert html =~ "No open incidents."
    end

    test "index inserts a proposal created elsewhere", %{
      conn: conn,
      owner: owner,
      project: project
    } do
      [parent_a, parent_b] = load_parents(project)
      result = result_for(project, "live-created")

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/demo/reviews")
      render_async(view)

      assert {:ok, created} =
               Proposals.create(%{id: owner.id}, %{
                 project_id: project.id,
                 kind: :meld,
                 parent_ids: [parent_a.id, parent_b.id],
                 result_tree_sha: result.tree,
                 meld_commit_sha: result.commit
               })

      assert render_async(view) =~ "proposal-#{created.id}"
    end

    test "index reflects a decision made elsewhere", %{
      conn: conn,
      owner: owner,
      project: project,
      proposal: proposal
    } do
      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/demo/reviews")
      assert render_async(view) =~ "pending"

      assert {:ok, _rejected} = Proposals.reject(%{id: owner.id}, project.id, proposal.id)

      html = render_async(view)
      assert html =~ "rejected"
      refute html =~ "pending"
    end

    test "show isolates the result when a proposal incident opens elsewhere", %{
      conn: conn,
      owner: owner,
      proposal: proposal
    } do
      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/demo/reviews/#{proposal.id}")
      html = render_async(view)
      assert html =~ "new.txt"
      assert html =~ "Approve"

      _incident = open_proposal_incident(proposal)

      html = render_async(view)
      assert html =~ "Result hidden for review"
      refute html =~ "Approve"
      assert html =~ "Reject"
    end

    test "show restores the result when the proposal incident is resolved elsewhere", %{
      conn: conn,
      owner: owner,
      project: project,
      proposal: proposal
    } do
      incident = open_proposal_incident(proposal)

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/demo/reviews/#{proposal.id}")
      assert render_async(view) =~ "Result hidden for review"

      assert {:ok, _resolved} =
               Incidents.resolve(%{id: owner.id}, project.id, incident.id,
                 verify: &ProposalView.verify_resolution/1
               )

      html = render_async(view)
      refute html =~ "Result hidden for review"
      assert html =~ "new.txt"
      assert html =~ "Approve"
    end

    test "show ignores a node incident opened elsewhere", %{
      conn: conn,
      owner: owner,
      project: project,
      proposal: proposal
    } do
      node = node_with_snapshot(project, %{"scan.txt" => "scan me"}, %{message: "scan node"})

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/demo/reviews/#{proposal.id}")
      assert render_async(view) =~ "Approve"

      open_node_incident(project, node)

      html = render_async(view)
      assert html =~ "new.txt"
      assert html =~ "Approve"
      refute html =~ "Result hidden for review"
    end

    test "show reflects a decision made on another socket", %{
      conn: conn,
      owner: owner,
      proposal: proposal
    } do
      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/demo/reviews/#{proposal.id}")
      {:ok, other, _html} = live(signed_conn(conn, owner), "/p/demo/reviews/#{proposal.id}")

      assert render_async(view) =~ "Approve"
      render_async(other)

      other |> element("button", "Approve") |> render_click()

      html = render_async(view)
      assert html =~ "approved"
      refute html =~ "Approve"
    end

    test "a critical incident on the promotion target blocks approval live", %{
      conn: conn,
      owner: owner,
      project: project
    } do
      target = node_with_snapshot(project, %{"promote.txt" => "ready"}, %{message: "promote me"})
      proposal = promotion_proposal(project, owner.id, target)

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/demo/reviews/#{proposal.id}")
      html = render_async(view)
      assert html =~ "Approve"
      refute html =~ "quarantines the node"

      open_node_incident(project, target)

      html = render_async(view)
      refute html =~ "Approve"
      assert html =~ "quarantines the node"
      assert html =~ "Reject"

      refused = render_click(view, "approve")
      assert refused =~ "critical incident is open"
      assert Repo.get!(Cadence.Server.Proposal, proposal.id).status == :pending
    end

    test "an incident on the existing meld node blocks re-approval", %{
      conn: conn,
      owner: owner,
      project: project,
      parent_a: parent_a,
      parent_b: parent_b
    } do
      result = result_for(project, "shared-meld")

      first = meld_proposal(project, owner.id, [parent_a, parent_b], result)
      assert {:ok, approved} = Proposals.approve(%{id: owner.id}, project.id, first.id)

      second = meld_proposal(project, owner.id, [parent_a, parent_b], result)
      node = Proposals.result_node(approved)
      assert node

      open_node_incident(project, node)

      {:ok, view, _html} = live(signed_conn(conn, owner), "/p/demo/reviews/#{second.id}")
      html = render_async(view)

      refute html =~ "Approve"
      assert html =~ "quarantines the node"
    end

    test "live updates still work for a mixed-case proposal URL", %{
      conn: conn,
      owner: owner,
      proposal: proposal
    } do
      path = "/p/demo/reviews/#{String.upcase(proposal.id)}"

      {:ok, view, _html} = live(signed_conn(conn, owner), path)
      assert render_async(view) =~ "Approve"

      _incident = open_proposal_incident(proposal)

      html = render_async(view)
      assert html =~ "Result hidden for review"
      refute html =~ "Approve"
    end

    test "revoking an approver grant removes the controls on the next event", %{
      conn: conn,
      project: project,
      proposal: proposal
    } do
      approver = seed_user("revoked@example.com", "Revoked Approver")
      membership(project, approver.id, :trusted, %{approver: true})

      node = node_with_snapshot(project, %{"scan.txt" => "scan me"}, %{message: "scan node"})
      open_node_incident(project, node)

      {:ok, index, _html} = live(signed_conn(conn, approver), "/p/demo/reviews")
      assert render_async(index) =~ ~s(phx-click="resolve_incident")

      {:ok, show, _html} = live(signed_conn(conn, approver), "/p/demo/reviews/#{proposal.id}")
      assert render_async(show) =~ "Approve"

      revoke_approver(project, approver.id)
      # A proposal-linked incident is one of the events Show reacts to, so it
      # must refresh the role as well as the payload.
      open_proposal_incident(proposal)

      refute render_async(index) =~ ~s(phx-click="resolve_incident")

      show_html = render_async(show)
      refute show_html =~ "Approve"
      refute show_html =~ "Reject"
      assert show_html =~ "pending"
    end
  end

  defp revoke_approver(project, user_id) do
    project.id
    |> then(&Repo.get_by!(Membership, project_id: &1, user_id: user_id))
    |> Ecto.Changeset.change(approver: false)
    |> Repo.update!()
  end

  defp open_node_incident(project, node) do
    {:ok, incident} =
      Incidents.open(%{
        project_id: project.id,
        node_id: node.id,
        kind: :secret_detected,
        severity: :critical,
        title: "Secret detected in snapshot",
        details: %{patterns: [:github_token]}
      })

    incident
  end

  defp open_proposal_incident(proposal) do
    {:ok, incident} =
      Incidents.open(%{
        project_id: proposal.project_id,
        proposal_id: proposal.id,
        kind: :secret_detected,
        severity: :critical,
        title: "Secret detected in meld result",
        details: %{patterns: [:github_token]}
      })

    incident
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
