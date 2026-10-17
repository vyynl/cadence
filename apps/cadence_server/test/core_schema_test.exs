defmodule Cadence.Server.CoreSchemaTest do
  use ExUnit.Case, async: false

  alias Cadence.Server.Repo
  alias Cadence.Shared.{Membership, Node, Project}

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  test "shared schemas round-trip on Postgres" do
    user_id = Ecto.UUID.generate()

    project =
      %Project{}
      |> Project.changeset(%{
        name: "Core",
        slug: "core",
        owner_id: user_id
      })
      |> Repo.insert!()

    node =
      %Node{}
      |> Node.changeset(%{
        project_id: project.id,
        git_commit_sha: String.duplicate("a", 40),
        flags: [:"in-progress"],
        created_by: user_id,
        docs_state: :pending
      })
      |> Repo.insert!()

    membership =
      %Membership{}
      |> Membership.changeset(%{
        user_id: user_id,
        project_id: project.id,
        role: :owner,
        active_heads: [node.id],
        session_pointer: node.id
      })
      |> Repo.insert!()

    assert Repo.get!(Project, project.id).slug == "core"
    assert Repo.get!(Node, node.id).parents == []

    assert Repo.get_by!(Membership, user_id: user_id, project_id: project.id).session_pointer ==
             node.id

    assert membership.active_heads == [node.id]
  end
end
