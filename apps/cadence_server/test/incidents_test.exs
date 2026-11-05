defmodule Cadence.Server.IncidentsTest do
  use ExUnit.Case, async: false

  import Cadence.ServerFixtures

  alias Cadence.Server.{Incident, Incidents, Repo}

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  describe "open/1 and list_open/2" do
    test "opens an incident and lists it for project members, critical first" do
      owner = Ecto.UUID.generate()
      viewer = Ecto.UUID.generate()
      stranger = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      membership(project, viewer, :viewer)
      node = node_fixture(project)

      assert {:ok, high} =
               Incidents.open(%{
                 project_id: project.id,
                 node_id: node.id,
                 kind: :scan_incomplete,
                 severity: :high,
                 title: "Scan incomplete",
                 details: %{reason: :caps_exceeded}
               })

      assert {:ok, critical} =
               Incidents.open(%{
                 project_id: project.id,
                 node_id: node.id,
                 kind: :secret_detected,
                 severity: :critical,
                 title: "Secret detected",
                 details: %{patterns: [:github_token]}
               })

      assert {:ok, [first, second]} = Incidents.list_open(actor(viewer), project.id)
      assert first.id == critical.id
      assert second.id == high.id

      assert Incidents.list_open(actor(stranger), project.id) == {:error, :forbidden}
      assert Incidents.list_open(actor(viewer), Ecto.UUID.generate()) == {:error, :not_found}
      assert Incidents.list_open(actor(viewer), "not-a-uuid") == {:error, :not_found}
    end

    test "list_open/2 caps the result at the most recent open incidents" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)

      for _ <- 1..(Incidents.max_open_incidents() + 2) do
        node = node_fixture(project)

        {:ok, _incident} =
          Incidents.open(%{
            project_id: project.id,
            node_id: node.id,
            kind: :scan_incomplete,
            severity: :high,
            title: "Scan incomplete",
            details: %{reason: :caps_exceeded}
          })
      end

      assert {:ok, incidents} = Incidents.list_open(actor(owner), project.id)
      assert length(incidents) == Incidents.max_open_incidents()
    end

    test "re-opening the same target and kind returns the existing incident" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      node = node_fixture(project)

      attrs = %{
        project_id: project.id,
        node_id: node.id,
        kind: :secret_detected,
        severity: :critical,
        title: "Secret detected",
        details: %{patterns: [:openai_key]}
      }

      assert {:ok, first} = Incidents.open(attrs)
      assert {:ok, second} = Incidents.open(attrs)
      assert second.id == first.id

      assert Repo.aggregate(Incident, :count) == 1
    end

    test "allows project-scoped incidents and dedupes them per project and kind" do
      owner = Ecto.UUID.generate()
      project = project(owner)

      attrs = %{
        project_id: project.id,
        kind: :meld_failed,
        severity: :high,
        title: "Meld failed",
        details: %{reason: :timeout}
      }

      assert {:ok, first} = Incidents.open(attrs)
      assert {:ok, again} = Incidents.open(attrs)
      assert again.id == first.id
      assert Repo.aggregate(Incident, :count) == 1

      other = project(Ecto.UUID.generate())
      assert {:ok, other_incident} = Incidents.open(%{attrs | project_id: other.id})
      assert other_incident.id != first.id
    end

    test "rejects an incident without a project" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Incidents.open(%{
                 kind: :meld_failed,
                 severity: :high,
                 title: "Meld failed",
                 details: %{}
               })

      assert changeset.errors[:project_id]
    end

    test "proposal-linked dedupe is unchanged by project-scoped incidents" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      proposal_id = Ecto.UUID.generate()

      attrs = %{
        project_id: project.id,
        proposal_id: proposal_id,
        kind: :agent_output_invalid,
        severity: :high,
        title: "Invalid agent output",
        details: %{reason: :malformed}
      }

      assert {:ok, first} = Incidents.open(attrs)
      assert {:ok, second} = Incidents.open(attrs)
      assert second.id == first.id
    end

    test "rejects secret-looking values in details" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      node = node_fixture(project)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Incidents.open(%{
                 project_id: project.id,
                 node_id: node.id,
                 kind: :secret_detected,
                 severity: :critical,
                 title: "Secret detected",
                 details: %{note: "api_key = abcdefghijklmnop"}
               })

      assert changeset.errors[:details]
    end
  end

  describe "blocking checks" do
    test "only open critical incidents block proposals and nodes" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      node = node_fixture(project)
      proposal_id = Ecto.UUID.generate()

      {:ok, high} =
        Incidents.open(%{
          project_id: project.id,
          proposal_id: proposal_id,
          kind: :meld_failed,
          severity: :high,
          title: "Meld failed",
          details: %{}
        })

      refute Incidents.blocking_proposal?(proposal_id)

      {:ok, critical} =
        Incidents.open(%{
          project_id: project.id,
          node_id: node.id,
          kind: :secret_detected,
          severity: :critical,
          title: "Secret detected",
          details: %{patterns: [:github_token]}
        })

      assert Incidents.blocking_node?(project.id, node.id)
      refute Incidents.blocking_node?(project.id, Ecto.UUID.generate())

      {:ok, _resolved} = Incidents.resolve(actor(owner), project.id, critical.id)
      refute Incidents.blocking_node?(project.id, node.id)

      assert {:ok, _resolved} = Incidents.resolve(actor(owner), project.id, high.id)
      refute Incidents.blocking_proposal?(proposal_id)
    end
  end

  describe "resolve/4" do
    test "owners and granted approvers may resolve; viewers and plain trusted may not" do
      owner = Ecto.UUID.generate()
      trusted = Ecto.UUID.generate()
      approver = Ecto.UUID.generate()
      viewer = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      membership(project, trusted, :trusted)
      membership(project, approver, :trusted, %{approver: true})
      membership(project, viewer, :viewer)
      node = node_fixture(project)

      incident = open_incident(project, node)

      assert Incidents.resolve(actor(viewer), project.id, incident.id) == {:error, :forbidden}

      assert Incidents.resolve(actor(trusted), project.id, incident.id) ==
               {:error, :forbidden}

      assert {:ok, resolved} = Incidents.resolve(actor(approver), project.id, incident.id)
      assert resolved.status == :resolved
      assert resolved.resolved_by == approver
      assert %DateTime{} = resolved.resolved_at
    end

    test "resolving twice is idempotent" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      node = node_fixture(project)
      incident = open_incident(project, node)

      assert {:ok, resolved} = Incidents.resolve(actor(owner), project.id, incident.id)
      assert {:ok, again} = Incidents.resolve(actor(owner), project.id, incident.id)
      assert again.id == resolved.id
      assert again.resolved_at == resolved.resolved_at
      assert again.resolved_by == resolved.resolved_by
    end

    test "a failed verification leaves the incident open" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      node = node_fixture(project)
      incident = open_incident(project, node)

      assert Incidents.resolve(actor(owner), project.id, incident.id,
               verify: fn _incident -> {:error, :still_risky} end
             ) == {:error, :still_risky}

      assert Incidents.blocking_node?(project.id, node.id)
      assert Repo.get!(Incident, incident.id).status == :open
    end

    test "re-resolving a resolved incident skips verification" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      membership(project, owner, :owner)
      node = node_fixture(project)
      incident = open_incident(project, node)

      assert {:ok, resolved} = Incidents.resolve(actor(owner), project.id, incident.id)

      assert {:ok, again} =
               Incidents.resolve(actor(owner), project.id, incident.id,
                 verify: fn _incident -> flunk("verification must not run twice") end
               )

      assert again.resolved_at == resolved.resolved_at
    end

    test "unknown or wrong-project incidents are not found" do
      owner = Ecto.UUID.generate()
      project = project(owner)
      other = project(Ecto.UUID.generate())
      membership(project, owner, :owner)
      membership(other, owner, :owner)
      node = node_fixture(project)
      incident = open_incident(project, node)

      assert Incidents.resolve(actor(owner), other.id, incident.id) == {:error, :not_found}

      assert Incidents.resolve(actor(owner), project.id, Ecto.UUID.generate()) ==
               {:error, :not_found}
    end
  end

  defp open_incident(project, node) do
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

  defp actor(user_id), do: %{id: user_id}
end
