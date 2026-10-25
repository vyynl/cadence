defmodule Cadence.Server.ProjectAdminTest do
  use ExUnit.Case, async: false

  alias Cadence.Server.{ProjectAdmin, Repo}
  alias Cadence.Shared.{Node, Project}

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  test "sets a node's pinned flag" do
    project = insert_project()
    node = insert_node(project)

    assert {:ok, updated} = ProjectAdmin.set_pinned(project.id, node.id, true)
    assert updated.pinned
    assert Repo.get!(Node, node.id).pinned

    assert {:ok, updated} = ProjectAdmin.set_pinned(project.id, node.id, false)
    refute updated.pinned
  end

  test "rejects nodes outside the project and invalid flags" do
    project = insert_project()
    other = insert_project("other")
    node = insert_node(other)

    assert ProjectAdmin.set_pinned(project.id, node.id, true) == {:error, :not_found}
    assert ProjectAdmin.set_pinned(project.id, "bad-id", true) == {:error, :not_found}
    assert ProjectAdmin.set_pinned(project.id, node.id, :yes) == {:error, :not_found}
  end

  defp insert_project(slug \\ "admin") do
    %Project{}
    |> Project.changeset(%{
      name: "Admin",
      slug: slug,
      owner_id: Ecto.UUID.generate()
    })
    |> Repo.insert!()
  end

  defp insert_node(project) do
    %Node{}
    |> Node.changeset(%{
      project_id: project.id,
      git_commit_sha: String.duplicate("e", 40),
      created_by: project.owner_id,
      created_at: DateTime.utc_now(),
      docs_state: :pending,
      flags: [:"in-progress"],
      message: "node"
    })
    |> Repo.insert!()
  end
end
