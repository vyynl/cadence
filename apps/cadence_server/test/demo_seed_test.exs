defmodule Cadence.Server.DemoSeedTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Cadence.Server.{ActionRun, DemoSeed, Proposals, Repo}
  alias Cadence.Server.Accounts.{Token, User}
  alias Cadence.Server.Proposal
  alias Cadence.Shared.{Membership, Node, Project}

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    artifact_path = Application.fetch_env!(:cadence_server, :artifact_path)
    on_exit(fn -> File.rm_rf!(artifact_path) end)
    :ok
  end

  test "builds two projects, four accounts and the expected memberships" do
    summary = DemoSeed.run()

    assert summary.fresh
    assert summary.password == "cadence-demo"

    assert summary.projects |> Enum.map(& &1.slug) |> Enum.sort() == [
             "cadence-demo",
             "meld-review"
           ]

    assert summary.users |> Enum.map(& &1.email) |> Enum.sort() == expected_emails()

    demo = project!("cadence-demo")
    review = project!("meld-review")

    assert membership!(demo, "owner@demo.local").role == :owner
    assert membership!(demo, "approver@demo.local").role == :viewer
    assert membership!(demo, "viewer@demo.local").role == :viewer

    assert membership!(review, "owner@demo.local").role == :owner
    approver = membership!(review, "approver@demo.local")
    assert approver.role == :trusted
    assert approver.approver

    assert membership!(review, "viewer@demo.local").role == :viewer
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

  test "seeded accounts sign in with the demo password" do
    DemoSeed.run()

    assert {:ok, user} =
             User
             |> Ash.Query.for_read(:sign_in_with_demo, %{
               email: "owner@demo.local",
               password: "cadence-demo"
             })
             |> Ash.read_one(domain: Cadence.Server.Accounts)

    assert to_string(user.email) == "owner@demo.local"
  end

  test "a second run is a no-op" do
    DemoSeed.run()
    before = counts()

    summary = DemoSeed.run()

    refute summary.fresh
    assert counts() == before
  end

  test "reset rebuilds the same dataset cleanly" do
    DemoSeed.run()
    before = counts()

    [run] = Repo.all(from(r in ActionRun, where: r.action_name == "run_analysis"))
    log_dir = Path.join(Application.fetch_env!(:cadence_server, :artifact_path), run.id)
    assert File.exists?(Path.join(log_dir, "output.log"))

    summary = DemoSeed.run(reset: true)

    assert summary.fresh
    assert counts() == before
    refute File.exists?(log_dir)
    assert length(proposals!(project!("meld-review"))) == 5
  end

  test "reset revokes auth tokens issued to the deleted demo users" do
    DemoSeed.run()
    owner = user!("owner@demo.local")
    subject = AshAuthentication.user_to_subject(owner)

    sign_in!("owner@demo.local", "cadence-demo")
    assert Repo.exists?(from(t in Token, where: t.subject == ^subject))

    DemoSeed.run(reset: true)

    refute Repo.exists?(from(t in Token, where: t.subject == ^subject))
    assert Repo.aggregate(from(u in User, where: u.email == "owner@demo.local"), :count) == 1
  end

  test "recovers from a partial first run" do
    {:ok, _user} =
      User
      |> Ash.Changeset.for_create(:create, %{
        email: "owner@demo.local",
        name: "Partial",
        hashed_password: Bcrypt.hash_pwd_salt("partial")
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

  defp sign_in!(email, password) do
    {:ok, user} =
      User
      |> Ash.Query.for_read(:sign_in_with_demo, %{email: email, password: password})
      |> Ash.read_one(domain: Cadence.Server.Accounts)

    user
  end

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
