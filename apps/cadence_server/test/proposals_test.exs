defmodule Cadence.Server.ProposalsTest do
  use ExUnit.Case, async: false

  import Cadence.ServerFixtures
  import Ecto.Query

  alias Cadence.Server.{Incident, Incidents, ProjectGit, Proposal, Proposals, Repo}
  alias Cadence.Shared.{GitStore, Node}

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  describe "create/2" do
    test "owner creates a pending meld proposal with a stable public token" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      [parent_a, parent_b] = meld_parents(project)

      assert {:ok, proposal} =
               Proposals.create(actor(owner), meld_attrs(project, [parent_a, parent_b]))

      assert proposal.status == :pending
      assert proposal.proposer_id == owner
      assert proposal.project_id == project.id
      assert proposal.kind == :meld
      assert byte_size(proposal.token) >= 32
      refute Enum.any?(["+", "/", "="], &String.contains?(proposal.token, &1))

      assert {:ok, fetched} = Proposals.get_by_token(proposal.token)
      assert fetched.id == proposal.id
      assert {:ok, ^fetched} = Proposals.get_by_token(proposal.token)
    end

    test "trusted members may propose; viewers and non-members may not" do
      owner = Ecto.UUID.generate()
      trusted = Ecto.UUID.generate()
      viewer = Ecto.UUID.generate()
      stranger = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      membership(project, trusted, :trusted)
      membership(project, viewer, :viewer)
      [parent_a, parent_b] = meld_parents(project)
      attrs = meld_attrs(project, [parent_a, parent_b])

      assert {:ok, _proposal} = Proposals.create(actor(trusted), attrs)
      assert Proposals.create(actor(viewer), attrs) == {:error, :forbidden}
      assert Proposals.create(actor(stranger), attrs) == {:error, :forbidden}
    end

    test "returns not_found for an unknown project" do
      owner = Ecto.UUID.generate()

      assert Proposals.create(actor(owner), %{
               project_id: Ecto.UUID.generate(),
               kind: :promotion,
               target_node_id: Ecto.UUID.generate()
             }) == {:error, :not_found}
    end

    test "meld proposals require two distinct parents and result SHAs" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      [parent_a, parent_b] = meld_parents(project)

      assert {:error, %Ecto.Changeset{}} =
               Proposals.create(actor(owner), %{project_id: project.id, kind: :meld})

      assert {:error, %Ecto.Changeset{}} =
               Proposals.create(
                 actor(owner),
                 meld_attrs(project, [parent_a]) |> Map.put(:parent_ids, [parent_a.id])
               )

      assert {:error, %Ecto.Changeset{}} =
               Proposals.create(
                 actor(owner),
                 meld_attrs(project, [parent_a, parent_b])
                 |> Map.put(:parent_ids, [parent_a.id, parent_a.id])
               )

      assert {:error, %Ecto.Changeset{}} =
               Proposals.create(actor(owner), %{
                 project_id: project.id,
                 kind: :meld,
                 parent_ids: [parent_a.id, parent_b.id]
               })

      assert {:error, %Ecto.Changeset{}} =
               Proposals.create(
                 actor(owner),
                 meld_attrs(project, [parent_a, parent_b])
                 |> Map.put(:result_tree_sha, "not-a-sha")
               )
    end

    test "meld parents must belong to the same project" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      other = project(Ecto.UUID.generate())
      membership(project, owner, :owner)
      parent_a = node_fixture(project)
      parent_b = node_fixture(other)

      assert Proposals.create(actor(owner), meld_attrs(project, [parent_a, parent_b])) ==
               {:error, :invalid_parent}
    end

    test "promotion proposals target an existing node in the same project" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      other = project(Ecto.UUID.generate())
      membership(project, owner, :owner)
      target = node_fixture(project)
      other_target = node_fixture(other)

      assert {:ok, proposal} =
               Proposals.create(actor(owner), %{
                 project_id: project.id,
                 kind: :promotion,
                 target_node_id: target.id
               })

      assert proposal.kind == :promotion
      assert proposal.target_node_id == target.id
      assert proposal.parent_ids == []

      assert Proposals.create(actor(owner), %{
               project_id: project.id,
               kind: :promotion,
               target_node_id: other_target.id
             }) == {:error, :invalid_target}

      assert {:error, %Ecto.Changeset{}} =
               Proposals.create(actor(owner), %{project_id: project.id, kind: :promotion})

      assert {:error, %Ecto.Changeset{}} =
               Proposals.create(actor(owner), %{
                 project_id: project.id,
                 kind: :promotion,
                 target_node_id: target.id,
                 parent_ids: [target.id]
               })
    end
  end

  describe "list/2 and get_by_token/1" do
    test "lists only the project's proposals for any member" do
      owner = Ecto.UUID.generate()
      viewer = Ecto.UUID.generate()
      stranger = Ecto.UUID.generate()
      project = project(owner)
      other = project(Ecto.UUID.generate())
      membership(project, owner, :owner)
      membership(project, viewer, :viewer)
      [parent_a, parent_b] = meld_parents(project)

      {:ok, proposal} = Proposals.create(actor(owner), meld_attrs(project, [parent_a, parent_b]))

      assert {:ok, [listed]} = Proposals.list(actor(viewer), project.id)
      assert listed.id == proposal.id

      assert Proposals.list(actor(stranger), project.id) == {:error, :forbidden}
      assert Proposals.list(actor(viewer), other.id) == {:error, :forbidden}
      assert Proposals.list(actor(viewer), Ecto.UUID.generate()) == {:error, :not_found}
      assert Proposals.list(actor(viewer), "not-a-uuid") == {:error, :not_found}
    end

    test "unknown tokens are not found" do
      assert Proposals.get_by_token("missing") == {:error, :not_found}
      assert Proposals.get_by_token(nil) == {:error, :not_found}
    end
  end

  describe "get/3" do
    test "members may read one proposal; strangers, other projects, and bad ids do not" do
      owner = Ecto.UUID.generate()
      viewer = Ecto.UUID.generate()
      stranger = Ecto.UUID.generate()
      project = project(owner)
      other = project(Ecto.UUID.generate())
      membership(project, owner, :owner)
      membership(project, viewer, :viewer)
      membership(other, owner, :owner)
      [parent_a, parent_b] = meld_parents(project)

      {:ok, proposal} =
        Proposals.create(actor(owner), meld_attrs(project, [parent_a, parent_b]))

      assert {:ok, fetched} = Proposals.get(actor(viewer), project.id, proposal.id)
      assert fetched.id == proposal.id

      assert Proposals.get(actor(stranger), project.id, proposal.id) == {:error, :forbidden}
      assert Proposals.get(actor(owner), other.id, proposal.id) == {:error, :not_found}
      assert Proposals.get(actor(owner), project.id, Ecto.UUID.generate()) == {:error, :not_found}
      assert Proposals.get(actor(owner), project.id, "not-a-uuid") == {:error, :not_found}

      assert Proposals.get(actor(owner), Ecto.UUID.generate(), proposal.id) ==
               {:error, :not_found}
    end
  end

  describe "result_integrity/2" do
    test "promotions carry no result and are always ok" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      target = node_fixture(project)
      proposal = promotion_proposal(project, owner, target)

      assert Proposals.result_integrity(project.id, proposal) == :ok
    end

    test "a meld is ok only when the commit exists and its tree is the result tree" do
      project = project(Ecto.UUID.generate())
      result = result(project)
      proposal = meld_struct(project, result)

      assert Proposals.result_integrity(project.id, proposal) == :ok

      assert Proposals.result_integrity(project.id, %{proposal | result_tree_sha: sha("b")}) ==
               {:error, :tree_mismatch}

      assert Proposals.result_integrity(project.id, %{proposal | meld_commit_sha: sha("d")}) ==
               {:error, :missing_objects}
    end

    test "a result SHA that is not a commit is rejected without raising" do
      project = project(Ecto.UUID.generate())

      blob_sha = GitStore.write_blob(ProjectGit.init(project.id), "not a commit")
      proposal = meld_struct(project, %{commit: blob_sha, tree: sha("b")})

      assert Proposals.result_integrity(project.id, proposal) == {:error, :not_a_commit}

      assert Proposals.result_integrity(project.id, %Proposal{kind: :meld}) ==
               {:error, :not_a_commit}
    end

    test "a result above the scan caps fails closed as too_large" do
      project = project(Ecto.UUID.generate())
      proposal = meld_struct(project, result(project))

      assert Proposals.result_integrity(project.id, proposal) == :ok

      assert Proposals.result_integrity(project.id, proposal, max_files: 0) ==
               {:error, :too_large}
    end

    test "a missing first parent is not approvable" do
      project = project(Ecto.UUID.generate())
      proposal = meld_struct(project, result(project))

      assert Proposals.result_integrity(project.id, proposal) == :ok

      [first | _rest] = proposal.parent_ids
      Repo.delete!(Repo.get!(Node, first))

      assert Proposals.result_integrity(project.id, proposal) == {:error, :missing_parent}
    end
  end

  describe "approve/3" do
    test "owners and granted approvers may decide; viewers and plain trusted may not" do
      owner = Ecto.UUID.generate()
      trusted = Ecto.UUID.generate()
      approver = Ecto.UUID.generate()
      viewer = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      membership(project, trusted, :trusted)
      membership(project, approver, :trusted, %{approver: true})
      membership(project, viewer, :viewer)
      [parent_a, parent_b] = meld_parents(project)

      {:ok, proposal_a} =
        Proposals.create(actor(owner), meld_attrs(project, [parent_a, parent_b]))

      {:ok, proposal_b} =
        Proposals.create(actor(owner), meld_attrs(project, [parent_a, parent_b]))

      {:ok, proposal_c} =
        Proposals.create(actor(owner), meld_attrs(project, [parent_a, parent_b]))

      assert Proposals.approve(actor(viewer), project.id, proposal_a.id) == {:error, :forbidden}

      assert Proposals.approve(actor(trusted), project.id, proposal_b.id) ==
               {:error, :forbidden}

      assert {:ok, approved} = Proposals.approve(actor(approver), project.id, proposal_c.id)
      assert approved.status == :approved
      assert approved.reviewer_id == approver
      assert %DateTime{} = approved.decided_at

      assert {:ok, owner_approved} = Proposals.approve(actor(owner), project.id, proposal_a.id)
      assert owner_approved.reviewer_id == owner
    end

    test "attaches exactly one meld node built from the proposal" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      [parent_a, parent_b] = meld_parents(project)
      result = result(project)

      {:ok, proposal} =
        Proposals.create(actor(owner), meld_attrs(project, [parent_a, parent_b], result))

      assert {:ok, approved} = Proposals.approve(actor(owner), project.id, proposal.id)

      assert [node] = nodes_with_commit(project, result.commit)
      assert node.project_id == project.id
      assert node.git_commit_sha == result.commit
      assert node.parents == proposal.parent_ids
      assert node.parents == [parent_a.id, parent_b.id]
      assert node.flags == [:"in-progress"]
      assert node.pinned
      assert node.docs_state == :pending
      assert node.created_by == owner
      assert node.message == "Meld of 2 sessions"

      assert approved.reviewer_id == owner
      assert %DateTime{} = approved.decided_at
      assert %{id: node_id} = Proposals.result_node(approved)
      assert node_id == node.id
    end

    test "re-approval is idempotent and creates no second node" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      [parent_a, parent_b] = meld_parents(project)
      result = result(project)

      {:ok, proposal} =
        Proposals.create(actor(owner), meld_attrs(project, [parent_a, parent_b], result))

      Phoenix.PubSub.subscribe(Cadence.Server.PubSub, "project:#{project.id}")

      assert {:ok, approved} = Proposals.approve(actor(owner), project.id, proposal.id)
      assert_receive {:nodes_pushed, _project_id, [_node_id]}

      assert {:ok, again} = Proposals.approve(actor(owner), project.id, proposal.id)

      assert again.id == approved.id
      assert again.decided_at == approved.decided_at
      assert again.reviewer_id == approved.reviewer_id
      assert length(nodes_with_commit(project, result.commit)) == 1
      assert_receive {:proposal_decided, _project_id, _proposal_id, :approved}
      refute_receive {:nodes_pushed, _project_id, _node_ids}
    end

    test "a second proposal for the same result reuses the already attached node" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      [parent_a, parent_b] = meld_parents(project)
      attrs = meld_attrs(project, [parent_a, parent_b])

      {:ok, first} = Proposals.create(actor(owner), attrs)
      {:ok, second} = Proposals.create(actor(owner), attrs)

      assert {:ok, _} = Proposals.approve(actor(owner), project.id, first.id)
      assert {:ok, second_approved} = Proposals.approve(actor(owner), project.id, second.id)

      assert [_single] = nodes_with_commit(project, attrs.meld_commit_sha)

      assert Proposals.result_node(second_approved).id ==
               hd(nodes_with_commit(project, attrs.meld_commit_sha)).id
    end

    test "a pre-existing node for the result commit is reused and pinned" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      [parent_a, parent_b] = meld_parents(project)
      attrs = meld_attrs(project, [parent_a, parent_b])
      existing = node_fixture(project, %{git_commit_sha: attrs.meld_commit_sha, pinned: false})
      {:ok, proposal} = Proposals.create(actor(owner), attrs)

      assert {:ok, approved} = Proposals.approve(actor(owner), project.id, proposal.id)

      assert Repo.get!(Node, existing.id).pinned
      assert length(project_nodes(project)) == 3
      assert Proposals.result_node(approved).id == existing.id
    end

    test "a reused node with an open critical incident stays unapprovable" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      [parent_a, parent_b] = meld_parents(project)
      attrs = meld_attrs(project, [parent_a, parent_b])
      existing = node_fixture(project, %{git_commit_sha: attrs.meld_commit_sha, pinned: false})
      {:ok, incident} = critical_node_incident(project, existing)
      {:ok, proposal} = Proposals.create(actor(owner), attrs)

      assert Proposals.approve(actor(owner), project.id, proposal.id) == {:error, :blocked}
      refute Repo.get!(Node, existing.id).pinned
      assert Repo.get!(Proposal, proposal.id).status == :pending

      assert {:ok, _resolved} = Incidents.resolve(actor(owner), project.id, incident.id)
      assert {:ok, _approved} = Proposals.approve(actor(owner), project.id, proposal.id)
      assert Repo.get!(Node, existing.id).pinned
    end

    test "promotion approval pins the target and creates no node" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      target = node_fixture(project, %{pinned: false})
      proposal = promotion_proposal(project, owner, target)
      before_count = length(project_nodes(project))

      assert {:ok, approved} = Proposals.approve(actor(owner), project.id, proposal.id)

      assert approved.status == :approved
      assert Repo.get!(Node, target.id).pinned
      assert length(project_nodes(project)) == before_count
      assert %{id: node_id} = Proposals.result_node(approved)
      assert node_id == target.id
      assert Proposals.result_node(proposal) == nil
    end

    test "a tree/commit mismatch fails integrity and stays pending" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      [parent_a, parent_b] = meld_parents(project)
      result = result(project)

      {:ok, proposal} =
        Proposals.create(
          actor(owner),
          meld_attrs(project, [parent_a, parent_b], result)
          |> Map.put(:result_tree_sha, sha("b"))
        )

      assert Proposals.approve(actor(owner), project.id, proposal.id) ==
               {:error, :integrity_failed}

      assert Repo.get!(Proposal, proposal.id).status == :pending
      assert nodes_with_commit(project, result.commit) == []
      assert incident = proposal_incident(proposal)
      assert incident.kind == :scan_incomplete
      assert incident.severity == :critical
      assert incident.status == :open
      assert incident.details["stage"] == "approval_integrity"
      assert incident.details["reason"] == "tree_mismatch"
    end

    test "missing result objects fail integrity and record the reason" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      [parent_a, parent_b] = meld_parents(project)

      {:ok, proposal} =
        Proposals.create(
          actor(owner),
          meld_attrs(project, [parent_a, parent_b]) |> Map.put(:meld_commit_sha, sha("d"))
        )

      assert Proposals.approve(actor(owner), project.id, proposal.id) ==
               {:error, :integrity_failed}

      assert Repo.get!(Proposal, proposal.id).status == :pending
      assert incident = proposal_incident(proposal)
      assert incident.details["reason"] == "missing_objects"
      assert project_nodes(project) |> length() == 2
    end

    test "a missing first parent fails approval and stays pending" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      [parent_a, parent_b] = meld_parents(project)

      {:ok, proposal} =
        Proposals.create(actor(owner), meld_attrs(project, [parent_a, parent_b]))

      Repo.delete!(Repo.get!(Node, parent_a.id))

      assert Proposals.approve(actor(owner), project.id, proposal.id) ==
               {:error, :integrity_failed}

      assert Repo.get!(Proposal, proposal.id).status == :pending
      assert nodes_with_commit(project, proposal.meld_commit_sha) == []
      assert incident = proposal_incident(proposal)
      assert incident.details["reason"] == "missing_parent"
    end

    test "an over-cap result fails approval and opens an incident" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      [parent_a, parent_b] = meld_parents(project)

      {:ok, proposal} =
        Proposals.create(actor(owner), meld_attrs(project, [parent_a, parent_b]))

      previous = Application.get_env(:cadence_server, :scan_max_files)

      try do
        Application.put_env(:cadence_server, :scan_max_files, 0)

        assert Proposals.approve(actor(owner), project.id, proposal.id) ==
                 {:error, :integrity_failed}
      after
        if previous do
          Application.put_env(:cadence_server, :scan_max_files, previous)
        else
          Application.delete_env(:cadence_server, :scan_max_files)
        end
      end

      assert Repo.get!(Proposal, proposal.id).status == :pending
      assert incident = proposal_incident(proposal)
      assert incident.details["reason"] == "too_large"
    end

    test "a parent commit whose tree is missing is not approvable" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      [parent_a, parent_b] = meld_parents(project)

      {:ok, proposal} =
        Proposals.create(actor(owner), meld_attrs(project, [parent_a, parent_b]))

      parent = Repo.get!(Node, parent_a.id)
      tree = GitStore.read_commit(ProjectGit.open(project.id), parent.git_commit_sha).tree
      File.rm!(object_path(project.id, tree))

      assert Proposals.approve(actor(owner), project.id, proposal.id) ==
               {:error, :integrity_failed}

      assert Repo.get!(Proposal, proposal.id).status == :pending
      assert incident = proposal_incident(proposal)
      assert incident.details["reason"] == "missing_parent"
    end

    test "a result SHA that is a blob fails integrity as not_a_commit" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      [parent_a, parent_b] = meld_parents(project)
      blob_sha = GitStore.write_blob(ProjectGit.init(project.id), "not a commit")

      {:ok, proposal} =
        Proposals.create(
          actor(owner),
          meld_attrs(project, [parent_a, parent_b]) |> Map.put(:meld_commit_sha, blob_sha)
        )

      assert Proposals.approve(actor(owner), project.id, proposal.id) ==
               {:error, :integrity_failed}

      assert Repo.get!(Proposal, proposal.id).status == :pending
      assert incident = proposal_incident(proposal)
      assert incident.details["reason"] == "not_a_commit"
      assert project_nodes(project) |> length() == 2
    end

    test "repeated integrity failures reuse one incident" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      [parent_a, parent_b] = meld_parents(project)

      {:ok, proposal} =
        Proposals.create(
          actor(owner),
          meld_attrs(project, [parent_a, parent_b]) |> Map.put(:meld_commit_sha, sha("d"))
        )

      assert Proposals.approve(actor(owner), project.id, proposal.id) ==
               {:error, :integrity_failed}

      # The first failure opened a critical incident, so the next attempt is
      # blocked before it can fail integrity again.
      assert Proposals.approve(actor(owner), project.id, proposal.id) == {:error, :blocked}

      assert Repo.aggregate(from(i in Incident, where: i.proposal_id == ^proposal.id), :count) ==
               1
    end

    test "a promotion whose target disappeared rolls back as not_found" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      target = node_fixture(project, %{pinned: false})
      proposal = promotion_proposal(project, owner, target)
      Repo.delete!(target)

      assert Proposals.approve(actor(owner), project.id, proposal.id) == {:error, :not_found}
      assert Repo.get!(Proposal, proposal.id).status == :pending
    end

    test "a promotion of a quarantined node stays unapprovable" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      target = node_fixture(project, %{pinned: false})
      proposal = promotion_proposal(project, owner, target)
      {:ok, incident} = critical_node_incident(project, target)

      assert Proposals.approve(actor(owner), project.id, proposal.id) == {:error, :blocked}
      refute Repo.get!(Node, target.id).pinned
      assert Repo.get!(Proposal, proposal.id).status == :pending

      assert {:ok, _resolved} = Incidents.resolve(actor(owner), project.id, incident.id)
      assert {:ok, _approved} = Proposals.approve(actor(owner), project.id, proposal.id)
      assert Repo.get!(Node, target.id).pinned
    end

    test "a critical open incident blocks approval until resolved" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      [parent_a, parent_b] = meld_parents(project)
      result = result(project)

      {:ok, proposal} =
        Proposals.create(actor(owner), meld_attrs(project, [parent_a, parent_b], result))

      assert {:ok, incident} =
               Incidents.open(%{
                 project_id: project.id,
                 proposal_id: proposal.id,
                 kind: :secret_detected,
                 severity: :critical,
                 title: "Secret detected",
                 details: %{patterns: [:github_token]}
               })

      assert Incidents.blocking_proposal?(proposal.id)

      assert Proposals.approve(actor(owner), project.id, proposal.id) == {:error, :blocked}
      assert nodes_with_commit(project, result.commit) == []

      assert {:ok, resolved} = Incidents.resolve(actor(owner), project.id, incident.id)
      assert resolved.status == :resolved
      refute Incidents.blocking_proposal?(proposal.id)

      assert {:ok, approved} = Proposals.approve(actor(owner), project.id, proposal.id)
      assert approved.status == :approved
      assert [_node] = nodes_with_commit(project, result.commit)
    end

    test "broadcasts the decision and the pushed node for a meld" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      [parent_a, parent_b] = meld_parents(project)
      result = result(project)

      {:ok, proposal} =
        Proposals.create(actor(owner), meld_attrs(project, [parent_a, parent_b], result))

      Phoenix.PubSub.subscribe(Cadence.Server.PubSub, "project:#{project.id}")

      assert {:ok, approved} = Proposals.approve(actor(owner), project.id, proposal.id)

      assert_receive {:proposal_decided, project_id, proposal_id, :approved}
      assert project_id == project.id
      assert proposal_id == approved.id

      assert_receive {:nodes_pushed, pushed_project_id, [node_id]}
      assert pushed_project_id == project.id
      assert node_id == Proposals.result_node(approved).id
    end

    test "a promotion approval broadcasts the decision, pins, and bumps the cursor" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      target = node_fixture(project, %{pinned: false})
      proposal = promotion_proposal(project, owner, target)
      original_seq = seq(target.id)

      Phoenix.PubSub.subscribe(Cadence.Server.PubSub, "project:#{project.id}")

      assert {:ok, approved} = Proposals.approve(actor(owner), project.id, proposal.id)

      assert_receive {:proposal_decided, project_id, proposal_id, :approved}
      assert project_id == project.id
      assert proposal_id == approved.id

      assert_receive {:nodes_pushed, ^project_id, [node_id]}
      assert node_id == target.id

      assert Repo.get!(Node, target.id).pinned
      assert seq(target.id) > original_seq
    end

    test "approving an already-pinned target emits no node-changed event" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      target = node_fixture(project, %{pinned: true})
      proposal = promotion_proposal(project, owner, target)
      original_seq = seq(target.id)

      Phoenix.PubSub.subscribe(Cadence.Server.PubSub, "project:#{project.id}")

      assert {:ok, _approved} = Proposals.approve(actor(owner), project.id, proposal.id)

      assert_receive {:proposal_decided, _project_id, _proposal_id, :approved}
      refute_receive {:nodes_pushed, _project_id, _node_ids}
      assert seq(target.id) == original_seq
    end

    test "every member's daemon is woken on a decision; a refusal wakes nobody" do
      owner = Ecto.UUID.generate()
      approver = Ecto.UUID.generate()
      stranger = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      membership(project, approver, :trusted, %{approver: true})
      [parent_a, parent_b] = meld_parents(project)
      {:ok, proposal} = Proposals.create(actor(owner), meld_attrs(project, [parent_a, parent_b]))

      for user_id <- [owner, approver, stranger] do
        Phoenix.PubSub.subscribe(Cadence.Server.PubSub, "sync:user:#{user_id}")
      end

      assert Proposals.approve(actor(stranger), project.id, proposal.id) == {:error, :forbidden}
      refute_receive {:sync_available, _project_id}

      assert {:ok, _approved} = Proposals.approve(actor(approver), project.id, proposal.id)

      assert_receive {:sync_available, project_id}
      assert project_id == project.id
      assert_receive {:sync_available, ^project_id}
      refute_receive {:sync_available, _project_id}
    end

    test "a refusal broadcasts nothing" do
      owner = Ecto.UUID.generate()
      viewer = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      membership(project, viewer, :viewer)
      [parent_a, parent_b] = meld_parents(project)
      {:ok, proposal} = Proposals.create(actor(owner), meld_attrs(project, [parent_a, parent_b]))

      Phoenix.PubSub.subscribe(Cadence.Server.PubSub, "project:#{project.id}")

      assert Proposals.approve(actor(viewer), project.id, proposal.id) == {:error, :forbidden}
      refute_receive {:proposal_decided, _project_id, _proposal_id, _status}
      refute_receive {:nodes_pushed, _project_id, _node_ids}
    end

    test "a failed integrity check broadcasts nothing" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      [parent_a, parent_b] = meld_parents(project)
      result = result(project)

      {:ok, proposal} =
        Proposals.create(
          actor(owner),
          meld_attrs(project, [parent_a, parent_b], result)
          |> Map.put(:result_tree_sha, sha("b"))
        )

      Phoenix.PubSub.subscribe(Cadence.Server.PubSub, "project:#{project.id}")

      assert Proposals.approve(actor(owner), project.id, proposal.id) ==
               {:error, :integrity_failed}

      refute_receive {:proposal_decided, _project_id, _proposal_id, _status}
      refute_receive {:nodes_pushed, _project_id, _node_ids}
    end

    test "a blocked approval broadcasts nothing" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      [parent_a, parent_b] = meld_parents(project)
      result = result(project)

      {:ok, proposal} =
        Proposals.create(actor(owner), meld_attrs(project, [parent_a, parent_b], result))

      {:ok, _incident} = critical_proposal_incident(project, proposal)

      Phoenix.PubSub.subscribe(Cadence.Server.PubSub, "project:#{project.id}")

      assert Proposals.approve(actor(owner), project.id, proposal.id) == {:error, :blocked}
      refute_receive {:proposal_decided, _project_id, _proposal_id, _status}
      refute_receive {:nodes_pushed, _project_id, _node_ids}
    end
  end

  describe "reject/3" do
    test "rejection skips the integrity check" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      [parent_a, parent_b] = meld_parents(project)

      {:ok, proposal} =
        Proposals.create(
          actor(owner),
          meld_attrs(project, [parent_a, parent_b]) |> Map.put(:meld_commit_sha, sha("d"))
        )

      assert {:ok, rejected} = Proposals.reject(actor(owner), project.id, proposal.id)
      assert rejected.status == :rejected

      assert Repo.aggregate(from(i in Incident, where: i.proposal_id == ^proposal.id), :count) ==
               0
    end

    test "rejection attaches nothing and cannot be flipped to approval" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      [parent_a, parent_b] = meld_parents(project)
      result = result(project)

      {:ok, proposal} =
        Proposals.create(actor(owner), meld_attrs(project, [parent_a, parent_b], result))

      assert {:ok, rejected} = Proposals.reject(actor(owner), project.id, proposal.id)
      assert rejected.status == :rejected
      assert rejected.reviewer_id == owner
      assert nodes_with_commit(project, result.commit) == []
      assert Proposals.result_node(rejected) == nil

      assert Proposals.approve(actor(owner), project.id, proposal.id) ==
               {:error, :invalid_transition}

      assert {:ok, rejected_again} = Proposals.reject(actor(owner), project.id, proposal.id)
      assert rejected_again.decided_at == rejected.decided_at
      assert rejected_again.reviewer_id == rejected.reviewer_id
    end

    test "a decided proposal cannot be rejected and an approval cannot be rejected" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      [parent_a, parent_b] = meld_parents(project)

      {:ok, approved_proposal} =
        Proposals.create(actor(owner), meld_attrs(project, [parent_a, parent_b]))

      assert {:ok, _approved} = Proposals.approve(actor(owner), project.id, approved_proposal.id)

      assert Proposals.reject(actor(owner), project.id, approved_proposal.id) ==
               {:error, :invalid_transition}
    end

    test "broadcasts only the decision" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      [parent_a, parent_b] = meld_parents(project)
      {:ok, proposal} = Proposals.create(actor(owner), meld_attrs(project, [parent_a, parent_b]))

      Phoenix.PubSub.subscribe(Cadence.Server.PubSub, "project:#{project.id}")

      assert {:ok, rejected} = Proposals.reject(actor(owner), project.id, proposal.id)
      assert_receive {:proposal_decided, _project_id, proposal_id, :rejected}
      assert proposal_id == rejected.id
      refute_receive {:nodes_pushed, _project_id, _node_ids}
    end
  end

  describe "approve/3 boundaries" do
    test "unknown or wrong-project proposals are not found" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      other = project(Ecto.UUID.generate())
      membership(project, owner, :owner)
      membership(other, owner, :owner)
      [parent_a, parent_b] = meld_parents(project)

      {:ok, proposal} =
        Proposals.create(actor(owner), meld_attrs(project, [parent_a, parent_b]))

      assert Proposals.approve(actor(owner), other.id, proposal.id) == {:error, :not_found}

      assert Proposals.approve(actor(owner), Ecto.UUID.generate(), proposal.id) ==
               {:error, :not_found}

      assert Proposals.approve(actor(owner), project.id, Ecto.UUID.generate()) ==
               {:error, :not_found}
    end
  end

  describe "result_node/1" do
    test "is nil until a meld is approved" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      [parent_a, parent_b] = meld_parents(project)
      {:ok, proposal} = Proposals.create(actor(owner), meld_attrs(project, [parent_a, parent_b]))

      assert Proposals.result_node(proposal) == nil
    end
  end

  describe "result_metadata" do
    test "defaults to an empty map, round-trips, and is never cast" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      [parent_a, parent_b] = meld_parents(project)

      assert {:ok, proposal} =
               Proposals.create(actor(owner), meld_attrs(project, [parent_a, parent_b]))

      assert proposal.result_metadata == %{}

      metadata = %{
        "provider" => "test-provider",
        "model" => "test-meld-model",
        "prompt_version" => "meld-v1",
        "ops" => %{"modify" => 1}
      }

      assert {:ok, _updated} =
               proposal
               |> Ecto.Changeset.change(result_metadata: metadata)
               |> Repo.update()

      assert Repo.get!(Proposal, proposal.id).result_metadata == metadata

      forged =
        Proposal.changeset(
          %Proposal{},
          Map.put(meld_attrs(project, [parent_a, parent_b]), :result_metadata, %{
            "provider" => "forged"
          })
        )

      assert Ecto.Changeset.get_field(forged, :result_metadata) == %{}
    end
  end

  defp actor(user_id), do: %{id: user_id}

  # Meld creation now requires real result objects so approval can verify them.
  defp meld_attrs(project, parents, result \\ nil) do
    result = result || result(project)

    %{
      project_id: project.id,
      kind: :meld,
      parent_ids: Enum.map(parents, & &1.id),
      result_tree_sha: result.tree,
      meld_commit_sha: result.commit
    }
  end

  defp result(project) do
    snapshot_tree(
      project,
      %{"lib/result.ex" => "defmodule Result do\nend\n"},
      "meld result #{System.unique_integer([:positive])}"
    )
  end

  defp project_nodes(project) do
    Repo.all(from(n in Node, where: n.project_id == ^project.id))
  end

  defp nodes_with_commit(project, commit_sha) do
    Repo.all(
      from(n in Node,
        where: n.project_id == ^project.id and n.git_commit_sha == ^commit_sha
      )
    )
  end

  defp proposal_incident(proposal) do
    Repo.one(from(i in Incident, where: i.proposal_id == ^proposal.id and i.status == :open)) ||
      flunk("expected an open incident for the proposal")
  end

  defp critical_proposal_incident(project, proposal) do
    Incidents.open(%{
      project_id: project.id,
      proposal_id: proposal.id,
      kind: :secret_detected,
      severity: :critical,
      title: "Secret detected",
      details: %{patterns: [:github_token]}
    })
  end

  defp critical_node_incident(project, node) do
    Incidents.open(%{
      project_id: project.id,
      node_id: node.id,
      kind: :secret_detected,
      severity: :critical,
      title: "Secret detected",
      details: %{patterns: [:github_token]}
    })
  end

  defp meld_struct(project, result) do
    %Proposal{
      project_id: project.id,
      kind: :meld,
      status: :pending,
      parent_ids: Enum.map(meld_parents(project), & &1.id),
      result_tree_sha: result.tree,
      meld_commit_sha: result.commit
    }
  end

  # Approval requires the first parent's commit to exist (the reviewer's diff
  # walks it), so meld parents in these tests are real snapshots, not rows with
  # a placeholder SHA.
  defp meld_parents(project) do
    sha = snapshot(project, %{"parent.txt" => "parent"}, "meld parent")
    [node_fixture(project, %{git_commit_sha: sha}), node_fixture(project, %{git_commit_sha: sha})]
  end

  defp object_path(project_id, sha) do
    Path.join([
      ProjectGit.path(project_id),
      "objects",
      String.slice(sha, 0, 2),
      String.slice(sha, 2, 38)
    ])
  end

  defp seq(node_id) do
    Repo.one(from(n in Node, where: n.id == ^node_id, select: fragment("seq")))
  end

  defp sha(char), do: String.duplicate(char, 40)
end
