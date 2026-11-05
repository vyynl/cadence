defmodule Cadence.Server.ProposalsTest do
  use ExUnit.Case, async: false

  import Cadence.ServerFixtures

  alias Cadence.Server.{Incidents, Proposal, Proposals, Repo}

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
      [parent_a, parent_b] = [node_fixture(project), node_fixture(project)]

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
      [parent_a, parent_b] = [node_fixture(project), node_fixture(project)]
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
      [parent_a, parent_b] = [node_fixture(project), node_fixture(project)]

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
      [parent_a, parent_b] = [node_fixture(project), node_fixture(project)]

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

  describe "approve/3 and reject/3" do
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
      [parent_a, parent_b] = [node_fixture(project), node_fixture(project)]

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

    test "duplicate decisions are idempotent and opposite transitions are rejected" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      [parent_a, parent_b] = [node_fixture(project), node_fixture(project)]

      {:ok, approved_proposal} =
        Proposals.create(actor(owner), meld_attrs(project, [parent_a, parent_b]))

      {:ok, rejected_proposal} =
        Proposals.create(actor(owner), meld_attrs(project, [parent_a, parent_b]))

      assert {:ok, approved} = Proposals.approve(actor(owner), project.id, approved_proposal.id)
      assert {:ok, again} = Proposals.approve(actor(owner), project.id, approved_proposal.id)
      assert again.id == approved.id
      assert again.decided_at == approved.decided_at
      assert again.reviewer_id == approved.reviewer_id

      assert {:ok, rejected} = Proposals.reject(actor(owner), project.id, rejected_proposal.id)

      assert {:ok, rejected_again} =
               Proposals.reject(actor(owner), project.id, rejected_proposal.id)

      assert rejected_again.id == rejected.id
      assert rejected_again.decided_at == rejected.decided_at

      assert Proposals.approve(actor(owner), project.id, rejected_proposal.id) ==
               {:error, :invalid_transition}

      assert Proposals.reject(actor(owner), project.id, approved_proposal.id) ==
               {:error, :invalid_transition}
    end

    test "a critical open incident blocks approval until resolved" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      [parent_a, parent_b] = [node_fixture(project), node_fixture(project)]

      {:ok, proposal} =
        Proposals.create(actor(owner), meld_attrs(project, [parent_a, parent_b]))

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

      assert {:ok, resolved} = Incidents.resolve(actor(owner), project.id, incident.id)
      assert resolved.status == :resolved
      refute Incidents.blocking_proposal?(proposal.id)

      assert {:ok, approved} = Proposals.approve(actor(owner), project.id, proposal.id)
      assert approved.status == :approved
    end

    test "unknown or wrong-project proposals are not found" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      other = project(Ecto.UUID.generate())
      membership(project, owner, :owner)
      membership(other, owner, :owner)
      [parent_a, parent_b] = [node_fixture(project), node_fixture(project)]

      {:ok, proposal} =
        Proposals.create(actor(owner), meld_attrs(project, [parent_a, parent_b]))

      assert Proposals.approve(actor(owner), other.id, proposal.id) == {:error, :not_found}

      assert Proposals.approve(actor(owner), project.id, Ecto.UUID.generate()) ==
               {:error, :not_found}
    end
  end

  describe "result_metadata" do
    test "defaults to an empty map, round-trips, and is never cast" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      [parent_a, parent_b] = [node_fixture(project), node_fixture(project)]

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

  defp meld_attrs(project, parents) do
    %{
      project_id: project.id,
      kind: :meld,
      parent_ids: Enum.map(parents, & &1.id),
      result_tree_sha: sha("b"),
      meld_commit_sha: sha("c")
    }
  end

  defp sha(char), do: String.duplicate(char, 40)
end
