defmodule Cadence.Server.PortfolioTest do
  use ExUnit.Case, async: false

  alias Cadence.Server.{Portfolio, Repo}
  alias Cadence.Shared.{Membership, Node, Project}

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  describe "get_project_by_slug/1" do
    test "returns the project" do
      project = insert_project("demo")

      assert {:ok, found} = Portfolio.get_project_by_slug("demo")
      assert found.id == project.id
    end

    test "returns :not_found for unknown or invalid slugs" do
      assert Portfolio.get_project_by_slug("missing") == {:error, :not_found}
      assert Portfolio.get_project_by_slug(nil) == {:error, :not_found}
    end
  end

  describe "list_nodes/1" do
    test "orders newest first and breaks timestamp ties by id" do
      project = insert_project()
      at = ~U[2026-10-24 12:00:00.000000Z]

      first =
        insert_node(project, %{
          id: "00000000-0000-0000-0000-000000000001",
          message: "first",
          created_at: at
        })

      second =
        insert_node(project, %{
          id: "00000000-0000-0000-0000-000000000002",
          message: "second",
          created_at: at
        })

      assert Enum.map(Portfolio.list_nodes(project.id), & &1.id) == [second.id, first.id]
    end

    test "returns [] for an invalid project id" do
      assert Portfolio.list_nodes("not-a-uuid") == []
    end
  end

  describe "preview_node/1" do
    test "prefers a pinned node over a newer functioning node" do
      project = insert_project()

      pinned =
        insert_node(project, %{
          pinned: true,
          message: "pinned",
          created_at: ~U[2026-10-20 00:00:00Z]
        })

      insert_node(project, %{
        flags: [:functioning],
        message: "functioning",
        created_at: ~U[2026-10-24 00:00:00Z]
      })

      assert Portfolio.preview_node(project.id).id == pinned.id
    end

    test "prefers a functioning node over a newer in-progress node" do
      project = insert_project()

      functioning =
        insert_node(project, %{
          flags: [:functioning],
          message: "functioning",
          created_at: ~U[2026-10-20 00:00:00Z]
        })

      insert_node(project, %{
        flags: [:"in-progress"],
        message: "in progress",
        created_at: ~U[2026-10-24 00:00:00Z]
      })

      assert Portfolio.preview_node(project.id).id == functioning.id
    end

    test "falls back to the newest node" do
      project = insert_project()

      insert_node(project, %{
        flags: [:"in-progress"],
        message: "older",
        created_at: ~U[2026-10-20 00:00:00Z]
      })

      newest =
        insert_node(project, %{
          flags: [:broken],
          message: "newest",
          created_at: ~U[2026-10-24 00:00:00Z]
        })

      assert Portfolio.preview_node(project.id).id == newest.id
    end

    test "returns nil when the project has no nodes" do
      project = insert_project()
      assert Portfolio.preview_node(project.id) == nil
    end

    test "returns nil for an invalid project id" do
      assert Portfolio.preview_node("not-a-uuid") == nil
    end
  end

  describe "membership_for/2" do
    test "returns the membership or nil" do
      project = insert_project()
      user_id = Ecto.UUID.generate()

      %Membership{}
      |> Membership.changeset(%{
        user_id: user_id,
        project_id: project.id,
        role: :owner
      })
      |> Repo.insert!()

      assert %{user_id: ^user_id, project_id: project_id} =
               Portfolio.membership_for(user_id, project.id)

      assert project_id == project.id
      assert Portfolio.membership_for(Ecto.UUID.generate(), project.id) == nil
      assert Portfolio.membership_for("nope", project.id) == nil
    end
  end

  defp insert_project(slug \\ "demo") do
    %Project{}
    |> Project.changeset(%{
      name: "Demo",
      slug: slug,
      owner_id: Ecto.UUID.generate()
    })
    |> Repo.insert!()
  end

  defp insert_node(project, attrs) do
    attrs =
      Map.merge(
        %{
          project_id: project.id,
          git_commit_sha: String.duplicate("a", 40),
          created_by: project.owner_id,
          created_at: DateTime.utc_now(),
          docs_state: :pending,
          flags: [:"in-progress"],
          message: "node"
        },
        attrs
      )

    %Node{}
    |> Node.changeset(attrs)
    |> Repo.insert!()
  end
end
