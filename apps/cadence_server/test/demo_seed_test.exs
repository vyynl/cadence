defmodule Cadence.Server.DemoSeedTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Cadence.Server.{ActionRun, DemoSeed, Portfolio, ProjectGit, Proposals, Repo}
  alias Cadence.Server.Accounts.{Token, User, UserSession}
  alias Cadence.Server.Proposal
  alias Cadence.Shared.{GitStore, Membership, Node, Project}

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    artifact_path = Application.fetch_env!(:cadence_server, :artifact_path)
    on_exit(fn -> File.rm_rf!(artifact_path) end)
    :ok
  end

  test "builds three projects, four accounts and the expected memberships" do
    summary = DemoSeed.run()

    assert summary.fresh
    assert summary.password == "cadence-demo"

    assert summary.projects |> Enum.map(& &1.slug) |> Enum.sort() == [
             "cadence-demo",
             "imported-demo",
             "meld-review"
           ]

    assert summary.users |> Enum.map(& &1.email) |> Enum.sort() == expected_emails()

    assert Repo.aggregate(Project, :count) == 3
    assert Repo.aggregate(Node, :count) == 169

    demo = project!("cadence-demo")
    review = project!("meld-review")
    imported = project!("imported-demo")

    assert demo.owner_id == user!("owner@demo.local").id
    assert review.owner_id == user!("owner@demo.local").id
    assert imported.owner_id == user!("owner@demo.local").id

    assert membership!(demo, "owner@demo.local").role == :owner
    assert membership!(demo, "approver@demo.local").role == :viewer
    assert membership!(demo, "viewer@demo.local").role == :viewer

    assert membership!(review, "owner@demo.local").role == :owner
    approver = membership!(review, "approver@demo.local")
    assert approver.role == :trusted
    assert approver.approver

    assert membership!(review, "viewer@demo.local").role == :viewer

    # The imported project is owner-only: no viewer/approver membership.
    assert membership!(imported, "owner@demo.local").role == :owner
    assert Repo.aggregate(from(m in Membership, where: m.project_id == ^imported.id), :count) == 1

    refute Repo.get_by(Membership, user_id: user!("outsider@demo.local").id)
  end

  test "cadence-demo covers every node flag, a pin and a quarantined node" do
    DemoSeed.run()

    demo = project!("cadence-demo")
    nodes = nodes!(demo)

    assert length(nodes) == 5
    assert Enum.count(nodes, & &1.pinned) == 1
    assert Enum.any?(nodes, &(:"in-progress" in &1.flags))
    assert Enum.any?(nodes, &(:functioning in &1.flags))
    assert Enum.any?(nodes, &(:broken in &1.flags))
    assert Enum.any?(nodes, &(:sandbox in &1.flags))
    assert Enum.all?(nodes, &(byte_size(&1.git_commit_sha) == 40))

    assert [incident] = open_incidents!(project: demo.id, node: true)
    assert incident.kind == :secret_detected
    assert incident.severity == :critical

    tainted = Enum.find(nodes, &(&1.id == incident.node_id))
    assert tainted
  end

  test "cadence-demo seeds one finished action run with a readable log" do
    DemoSeed.run()

    demo = project!("cadence-demo")
    pinned = Enum.find(nodes!(demo), & &1.pinned)

    assert [run] = Repo.all(from(r in ActionRun, where: r.project_id == ^demo.id))
    assert run.status == :succeeded
    assert run.exit_code == 0
    assert run.node_id == pinned.id
    assert run.action_name == "run_analysis"
    assert {:ok, log} = Cadence.Server.Actions.Runs.log(run)
    assert log =~ "cadence demo action"
  end

  test "meld-review has proposals in every review state" do
    DemoSeed.run()

    review = project!("meld-review")
    proposals = proposals!(review)

    assert length(proposals) == 5
    assert Enum.count(proposals, &(&1.status == :pending)) == 3
    assert Enum.count(proposals, &(&1.status == :approved)) == 1
    assert Enum.count(proposals, &(&1.status == :rejected)) == 1

    assert Enum.count(proposals, &(&1.kind == :promotion)) == 1
    assert Enum.count(proposals, &(&1.kind == :meld)) == 4

    approved = Enum.find(proposals, &(&1.status == :approved))
    node = Proposals.result_node(approved)
    assert node
    assert node.pinned
    assert node.git_commit_sha == approved.meld_commit_sha

    isolated = Enum.find(proposals, &(&1.result_metadata == %{"demo" => "isolated_meld"}))
    assert [incident] = open_incidents!(project: review.id, proposal: isolated.id)
    assert incident.kind == :secret_detected

    assert {:error, :blocked} =
             Proposals.approve(%{id: user!("owner@demo.local").id}, review.id, isolated.id)

    # The approved meld's result is intact: integrity passes for a fresh check.
    assert :ok = Proposals.result_integrity(review.id, approved)
  end

  test "imported-demo preserves import topology, timestamps and provenance" do
    DemoSeed.run()

    imported = project!("imported-demo")
    nodes = nodes!(imported)

    assert length(nodes) == 160
    assert nodes |> Enum.map(& &1.git_commit_sha) |> Enum.uniq() |> length() == 160
    assert Enum.all?(nodes, &(byte_size(&1.git_commit_sha) == 40))
    assert Enum.all?(nodes, &(&1.flags == []))
    assert Enum.all?(nodes, &(&1.docs_state == :skipped))

    # Exactly the tip is pinned, and it is the project preview.
    assert [tip] = Enum.filter(nodes, & &1.pinned)
    assert Portfolio.preview_node(imported.id).id == tip.id
    assert tip.session_metadata["import"]["refs"] == ["refs/heads/main"]

    # Every parent is a node in this project; the root has none.
    by_id = Map.new(nodes, &{&1.id, &1})
    by_sha = Map.new(nodes, &{&1.git_commit_sha, &1.id})
    assert hd(nodes).parents == []

    assert Enum.all?(nodes, fn node ->
             Enum.all?(node.parents, &Map.has_key?(by_id, &1))
           end)

    # Exactly one merge, with its two parents preserved in commit order.
    assert [merge] = Enum.filter(nodes, &(length(&1.parents) == 2))
    assert merge.message == "Merge branch 'feature/import-ui' into main"
    assert length(Enum.uniq(merge.parents)) == 2

    commit = GitStore.read_commit(ProjectGit.open(imported.id), merge.git_commit_sha)
    assert Enum.map(commit.parent, &Map.fetch!(by_sha, &1)) == merge.parents
    assert commit.author.timestamp == DateTime.to_unix(merge.created_at)
    assert commit.author.name == merge.session_metadata["import"]["author"]
    assert commit.author.email == merge.session_metadata["import"]["author_email"]

    # Provenance is complete and varied, with refs only on the tip.
    imports = Enum.map(nodes, & &1.session_metadata["import"])
    assert Enum.all?(imports, &(&1["source"] == "git"))
    assert Enum.all?(imports, &(is_binary(&1["author"]) and is_binary(&1["author_email"])))
    assert Enum.all?(imports, &is_binary(&1["imported_at"]))
    assert imports |> Enum.map(& &1["author"]) |> Enum.uniq() |> length() >= 3
    assert Enum.count(imports, &Map.has_key?(&1, "refs")) == 1
  end

  test "an imported historical snapshot is quarantined and pages in History" do
    DemoSeed.run()

    imported = project!("imported-demo")
    [incident] = open_incidents!(project: imported.id, node: true)
    assert incident.kind == :secret_detected
    assert incident.severity == :critical
    assert "github_token" in Map.fetch!(incident.details, "patterns")

    node = Repo.get!(Node, incident.node_id)
    assert node.docs_state == :skipped
    assert node.flags == []
    assert Portfolio.quarantine_status(imported, node) == :quarantined

    # The secret commit is one of the ten oldest, so the capped DAG omits it
    # and only History can reach it.
    cap = Application.fetch_env!(:cadence_server, :dag_max_nodes)
    visible = Portfolio.list_nodes(imported.id, limit: cap)
    assert length(visible) == cap
    refute Enum.any?(visible, &(&1.id == node.id))

    page = Portfolio.node_page(imported.id, 4)
    assert page.total == 160
    assert page.total_pages == 4
    assert Enum.any?(page.nodes, &(&1.id == node.id))
  end

  test "seeded accounts sign in with the demo password" do
    DemoSeed.run()

    user =
      Cadence.Server.Accounts.LocalAuth.get_user_by_email_and_password(
        "owner@demo.local",
        "cadence-demo"
      )

    assert to_string(user.email) == "owner@demo.local"
  end

  test "a second run is a no-op" do
    DemoSeed.run()
    before = counts()

    summary = DemoSeed.run()

    refute summary.fresh
    assert counts() == before
    assert length(nodes!(project!("imported-demo"))) == 160
  end

  test "reset rebuilds the same dataset cleanly" do
    DemoSeed.run()
    before = counts()
    old_imported = project!("imported-demo")

    [run] = Repo.all(from(r in ActionRun, where: r.action_name == "run_analysis"))
    log_dir = Path.join(Application.fetch_env!(:cadence_server, :artifact_path), run.id)
    assert File.exists?(Path.join(log_dir, "output.log"))

    summary = DemoSeed.run(reset: true)

    assert summary.fresh
    assert counts() == before
    refute File.exists?(log_dir)
    assert length(proposals!(project!("meld-review"))) == 5

    imported = project!("imported-demo")
    assert imported.id != old_imported.id
    refute File.exists?(ProjectGit.path(old_imported.id))
    assert length(nodes!(imported)) == 160
    assert [_incident] = open_incidents!(project: imported.id, node: true)
  end

  test "reset revokes browser sessions issued to the deleted demo users" do
    DemoSeed.run()
    owner = user!("owner@demo.local")

    conn = Plug.Test.init_test_session(Plug.Test.conn(:get, "/"), %{})
    {_conn, session} = Cadence.ServerWeb.UserAuth.log_in(conn, owner)
    assert Repo.exists?(from(s in UserSession, where: s.id == ^session.id))

    DemoSeed.run(reset: true)

    refute Repo.exists?(from(s in UserSession, where: s.user_id == ^owner.id))
    assert Repo.aggregate(from(u in User, where: u.email == "owner@demo.local"), :count) == 1
  end

  test "recovers from a partial first run" do
    {:ok, _user} =
      User
      |> Ash.Changeset.for_create(:create, %{
        email: "owner@demo.local",
        name: "Partial",
        hashed_password: Cadence.Server.Accounts.LocalAuth.hash_password("partial password")
      })
      |> Ash.create(domain: Cadence.Server.Accounts)

    summary = DemoSeed.run()

    assert summary.fresh
    assert length(proposals!(project!("meld-review"))) == 5
    assert Repo.aggregate(from(u in User, where: u.email == "owner@demo.local"), :count) == 1
  end

  defp counts do
    %{
      projects: Repo.aggregate(Project, :count),
      nodes: Repo.aggregate(Node, :count),
      memberships: Repo.aggregate(Membership, :count),
      proposals: Repo.aggregate(Proposal, :count),
      runs: Repo.aggregate(ActionRun, :count),
      users: Repo.aggregate(User, :count),
      tokens: Repo.aggregate(Token, :count)
    }
  end

  defp expected_emails do
    ~w(approver@demo.local outsider@demo.local owner@demo.local viewer@demo.local)
  end

  defp user!(email), do: Repo.one!(from(u in User, where: u.email == ^email))

  defp project!(slug), do: Repo.one!(from(p in Project, where: p.slug == ^slug))

  defp membership!(project, email) do
    user = user!(email)
    Repo.one!(from(m in Membership, where: m.project_id == ^project.id and m.user_id == ^user.id))
  end

  defp nodes!(project) do
    Repo.all(from(n in Node, where: n.project_id == ^project.id, order_by: [asc: n.created_at]))
  end

  defp proposals!(project) do
    Repo.all(from(p in Proposal, where: p.project_id == ^project.id))
  end

  defp open_incidents!(opts) do
    query =
      from(i in Cadence.Server.Incident,
        where: i.project_id == ^opts[:project] and i.status == :open
      )

    query =
      if opts[:node],
        do: where(query, [i], not is_nil(i.node_id)),
        else: where(query, [i], i.proposal_id == ^opts[:proposal])

    incidents = Repo.all(query)
    assert length(incidents) == 1
    incidents
  end
end
