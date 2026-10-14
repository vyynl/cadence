defmodule Cadence.Daemon.RepoTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Cadence.Daemon.Repo
  alias Cadence.Shared.{Membership, Node, Project}

  test "round-trips a project, node, and membership through SQLite" do
    owner_id = Ecto.UUID.generate()

    {:ok, project} =
      %{
        name: "Cadence",
        slug: "cadence-#{System.unique_integer([:positive])}",
        owner_id: owner_id
      }
      |> Project.changeset()
      |> Repo.insert()

    assert project.id

    {:ok, node} =
      %{
        project_id: project.id,
        git_commit_sha: String.duplicate("a", 40),
        parents: [],
        flags: [:functioning, :"in-progress"],
        message: "initial",
        session_metadata: %{"files" => ["a.ex"], "duration_ms" => 120},
        created_by: owner_id,
        docs_state: :current
      }
      |> Node.changeset()
      |> Repo.insert()

    loaded = Repo.get!(Node, node.id)
    assert loaded.parents == []
    assert loaded.flags == [:functioning, :"in-progress"]
    assert loaded.session_metadata == %{"files" => ["a.ex"], "duration_ms" => 120}
    assert loaded.docs_state == :current

    {:ok, _membership} =
      %{
        user_id: owner_id,
        project_id: project.id,
        role: :owner,
        approver: true,
        active_heads: [node.id],
        session_pointer: node.id
      }
      |> Membership.changeset()
      |> Repo.insert()

    membership =
      Repo.one!(
        from(m in Membership,
          where: m.user_id == ^owner_id and m.project_id == ^project.id
        )
      )

    assert membership.role == :owner
    assert membership.approver == true
    assert membership.active_heads == [node.id]
    assert membership.session_pointer == node.id
  end
end
