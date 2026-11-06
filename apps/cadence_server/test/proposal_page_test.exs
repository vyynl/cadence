defmodule Cadence.ServerWeb.ProposalPageTest do
  use Cadence.ServerWeb.ConnCase, async: false

  import Cadence.ServerFixtures

  alias Cadence.Server.{Incidents, Proposals}
  alias Cadence.Server.Accounts.User

  setup do
    owner = Ecto.UUID.generate()
    project = project(owner, %{name: "Demo Project", slug: "demo-proposal"})
    membership(project, owner, :owner)

    parent_a =
      node_with_snapshot(
        project,
        %{"keep.txt" => "same", "edit.txt" => "v1", "gone.txt" => "bye"},
        %{message: "first parent"}
      )

    parent_b =
      node_with_snapshot(project, %{"keep.txt" => "same"}, %{message: "second parent"})

    result =
      snapshot_tree(
        project,
        %{"keep.txt" => "same", "edit.txt" => "v2", "new.txt" => "hi"},
        "meld result",
        [parent_a.git_commit_sha, parent_b.git_commit_sha]
      )

    proposal = meld_proposal(project, owner, [parent_a, parent_b], result)

    %{
      project: project,
      owner: owner,
      parent_a: parent_a,
      parent_b: parent_b,
      result: result,
      proposal: proposal
    }
  end

  test "unknown token renders a 404", %{conn: conn} do
    conn = get(conn, "/proposals/no-such-token")

    assert conn.status == 404
    assert html_response(conn, 404) =~ "Proposal not found"
  end

  test "renders a meld proposal with metadata, parents, and the file-level diff", %{
    conn: conn,
    project: project,
    parent_a: parent_a,
    parent_b: parent_b,
    proposal: proposal
  } do
    html = conn |> get("/proposals/#{proposal.token}") |> html_response(200)

    assert html =~ "Meld proposal"
    assert html =~ "pending"
    assert html =~ "created"
    assert html =~ project.name

    assert html =~ ~s(href="/p/#{project.slug}/n/#{parent_a.id}")
    assert html =~ ~s(href="/p/#{project.slug}/n/#{parent_b.id}")
    assert html =~ "first parent"
    assert html =~ "second parent"
    assert html =~ String.slice(parent_a.git_commit_sha, 0, 12)

    assert html =~ "1 added"
    assert html =~ "1 modified"
    assert html =~ "1 deleted"
    assert html =~ "new.txt"
    assert html =~ "edit.txt"
    assert html =~ "gone.txt"
    refute html =~ "keep.txt"
    assert html =~ "Approval is not available on this page."

    assert html =~ "badge status-badge status-pending"
    assert html =~ "file-status file-status-added"
    assert html =~ "file-status file-status-modified"
    assert html =~ "file-status file-status-deleted"
    assert html =~ ~s(class="callout callout-note")
  end

  test "hides a sensitive result path and counts it", %{
    conn: conn,
    project: project,
    owner: owner,
    parent_a: parent_a,
    parent_b: parent_b
  } do
    result = snapshot_tree(project, %{"notes.txt" => "two", ".env" => "plain-value"}, "result")
    proposal = meld_proposal(project, owner, [parent_a, parent_b], result)

    html = conn |> get("/proposals/#{proposal.token}") |> html_response(200)

    assert html =~ "1 file hidden for security"
    assert html =~ "notes.txt"
    refute html =~ ".env"
  end

  test "quarantines a result that contains a secret value", %{
    conn: conn,
    project: project,
    owner: owner,
    parent_a: parent_a,
    parent_b: parent_b
  } do
    result =
      snapshot_tree(
        project,
        %{"config.txt" => "token: ghp_abcdefghijklmnopqrstuvwxyz0123456789\n"},
        "result"
      )

    proposal = meld_proposal(project, owner, [parent_a, parent_b], result)

    html = conn |> get("/proposals/#{proposal.token}") |> html_response(200)

    assert html =~ "Result hidden for review"
    refute html =~ "config.txt"
    refute html =~ "compared with the first parent"
    assert html =~ "pending"
  end

  test "isolates the result while a critical incident is open", %{
    conn: conn,
    project: project,
    parent_a: parent_a,
    proposal: proposal
  } do
    incident = open_incident(project, proposal)

    html = conn |> get("/proposals/#{proposal.token}") |> html_response(200)

    assert html =~ "Result hidden for review"
    refute html =~ "new.txt"
    refute html =~ "compared with the first parent"

    # Metadata and parents are not result content and stay visible.
    assert html =~ "pending"
    assert html =~ "first parent"
    assert html =~ ~s(href="/p/#{project.slug}/n/#{parent_a.id}")

    assert {:ok, _resolved} = Incidents.resolve(%{id: project.owner_id}, project.id, incident.id)

    html = conn |> get("/proposals/#{proposal.token}") |> html_response(200)

    assert html =~ "new.txt"
    refute html =~ "Result hidden for review"
  end

  test "never renders proposer or reviewer identities to an anonymous visitor", %{
    conn: conn,
    project: project,
    parent_a: parent_a,
    parent_b: parent_b,
    result: result
  } do
    proposer =
      Ash.Seed.seed!(User, %{email: "proposer-zealot@example.com", name: "Zelda Proposer"})

    reviewer =
      Ash.Seed.seed!(User, %{email: "reviewer-zealot@example.com", name: "Rhea Reviewer"})

    membership(project, reviewer.id, :trusted, %{approver: true})

    proposal = meld_proposal(project, proposer.id, [parent_a, parent_b], result)

    assert {:ok, approved} = Proposals.approve(%{id: reviewer.id}, project.id, proposal.id)
    assert approved.status == :approved

    html = conn |> get("/proposals/#{proposal.token}") |> html_response(200)

    assert html =~ "approved"
    refute html =~ "proposer-zealot@example.com"
    refute html =~ "reviewer-zealot@example.com"
    refute html =~ "Zelda Proposer"
    refute html =~ "Rhea Reviewer"
    refute html =~ proposer.id
    refute html =~ reviewer.id
  end

  test "renders a promotion proposal without a diff section", %{
    conn: conn,
    project: project,
    owner: owner,
    parent_a: parent_a
  } do
    proposal = promotion_proposal(project, owner, parent_a)

    html = conn |> get("/proposals/#{proposal.token}") |> html_response(200)

    assert html =~ "Promotion proposal"
    assert html =~ "View the target node"
    assert html =~ ~s(href="/p/#{project.slug}/n/#{parent_a.id}")
    assert html =~ "No parent nodes are available."
    refute html =~ "compared with the first parent"
    refute html =~ "No file changes"
  end

  test "reports a missing meld result without failing", %{
    conn: conn,
    project: project,
    owner: owner,
    parent_a: parent_a,
    parent_b: parent_b,
    result: result
  } do
    bogus = String.duplicate("b", 40)

    proposal =
      meld_proposal(project, owner, [parent_a, parent_b], result, %{
        meld_commit_sha: bogus,
        result_tree_sha: bogus
      })

    html = conn |> get("/proposals/#{proposal.token}") |> html_response(200)

    assert html =~ "The meld result is not available yet."
  end

  test "keeps the token stable across reads and canonical", %{
    conn: conn,
    proposal: proposal
  } do
    path = "/proposals/#{proposal.token}"

    first = conn |> get(path) |> html_response(200)
    second = conn |> get(path) |> html_response(200)

    normalize = fn html -> String.replace(html, ~r/<meta name="csrf-token"[^>]*>/, "") end

    assert normalize.(first) == normalize.(second)
    assert String.length(proposal.token) >= 32

    assert first =~
             ~s(rel="canonical" href="http://localhost:4000/proposals/#{proposal.token}")
  end

  test "rejects mutation verbs", %{proposal: proposal} do
    path = "/proposals/#{proposal.token}"

    assert post(build_conn(), path, %{}).status == 404
    assert patch(build_conn(), path, %{}).status == 404
    assert put(build_conn(), path, %{}).status == 404
    assert delete(build_conn(), path).status == 404
  end

  test "renders approved and rejected decisions with their timestamp", %{
    conn: conn,
    project: project,
    owner: owner,
    parent_a: parent_a,
    parent_b: parent_b,
    result: result,
    proposal: proposal
  } do
    assert {:ok, _approved} = Proposals.approve(%{id: owner}, project.id, proposal.id)

    approved_html = conn |> get("/proposals/#{proposal.token}") |> html_response(200)
    assert approved_html =~ "approved"
    assert approved_html =~ "decided"

    rejected = meld_proposal(project, owner, [parent_a, parent_b], result)
    assert {:ok, _rejected} = Proposals.reject(%{id: owner}, project.id, rejected.id)

    rejected_html = conn |> get("/proposals/#{rejected.token}") |> html_response(200)
    assert rejected_html =~ "rejected"
    assert rejected_html =~ "decided"
  end

  test "renders a 404 when the proposal points at a missing project", %{
    conn: conn,
    owner: owner,
    parent_a: parent_a,
    parent_b: parent_b,
    result: result
  } do
    orphan =
      proposal(%{
        project_id: Ecto.UUID.generate(),
        proposer_id: owner,
        kind: :meld,
        parent_ids: [parent_a.id, parent_b.id],
        result_tree_sha: result.tree,
        meld_commit_sha: result.commit
      })

    conn = get(conn, "/proposals/#{orphan.token}")

    assert conn.status == 404
    assert html_response(conn, 404) =~ "Proposal not found"
  end

  test "reports an oversized result without failing", %{
    conn: conn,
    project: project,
    owner: owner,
    parent_a: parent_a,
    parent_b: parent_b
  } do
    result = snapshot_tree(project, %{"large.txt" => String.duplicate("a", 70_000)}, "result")
    proposal = meld_proposal(project, owner, [parent_a, parent_b], result)

    html = conn |> get("/proposals/#{proposal.token}") |> html_response(200)

    assert html =~ "The result is too large to review in the browser."
  end

  test "does not isolate a promotion behind an open critical incident", %{
    conn: conn,
    project: project,
    owner: owner,
    parent_a: parent_a
  } do
    proposal = promotion_proposal(project, owner, parent_a)
    _incident = open_incident(project, proposal)

    html = conn |> get("/proposals/#{proposal.token}") |> html_response(200)

    assert html =~ "View the target node"
    assert html =~ ~s(href="/p/#{project.slug}/n/#{parent_a.id}")
    refute html =~ "Result hidden for review"
  end

  test "notes a truncated file list", %{
    conn: conn,
    project: project,
    owner: owner,
    parent_a: parent_a,
    parent_b: parent_b,
    result: result
  } do
    previous = Application.get_env(:cadence_server, :proposal_max_files)
    on_exit(fn -> Application.put_env(:cadence_server, :proposal_max_files, previous) end)
    Application.put_env(:cadence_server, :proposal_max_files, 1)

    proposal = meld_proposal(project, owner, [parent_a, parent_b], result)

    html = conn |> get("/proposals/#{proposal.token}") |> html_response(200)

    assert html =~ "The file list is truncated."
  end

  test "never renders blob content, only paths and statuses", %{
    conn: conn,
    project: project,
    owner: owner,
    parent_a: parent_a,
    parent_b: parent_b
  } do
    result =
      snapshot_tree(
        project,
        %{"marker.txt" => "BLOB_CONTENT_MARKER_SHOULD_NOT_APPEAR"},
        "result"
      )

    proposal = meld_proposal(project, owner, [parent_a, parent_b], result)

    html = conn |> get("/proposals/#{proposal.token}") |> html_response(200)

    assert html =~ "marker.txt"
    refute html =~ "BLOB_CONTENT_MARKER_SHOULD_NOT_APPEAR"
  end

  describe "access logging" do
    test "suppresses request logging for proposal capability URLs" do
      assert Cadence.ServerWeb.Endpoint.log_level(%{path_info: ["proposals", "abc"]}) == false
      assert Cadence.ServerWeb.Endpoint.log_level(%{path_info: ["p", "demo"]}) == :info
    end
  end

  defp open_incident(project, proposal) do
    {:ok, incident} =
      Incidents.open(%{
        project_id: project.id,
        proposal_id: proposal.id,
        kind: :secret_detected,
        severity: :critical,
        title: "Secret detected in meld result",
        details: %{patterns: [:github_token]}
      })

    incident
  end
end
