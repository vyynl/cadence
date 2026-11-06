defmodule Cadence.Server.ActionsTest do
  use ExUnit.Case, async: false

  alias Cadence.Server.{Actions, ProjectGit, Repo}
  alias Cadence.Server.Accounts.User
  alias Cadence.Shared.{GitStore, Membership, Node, Project}

  @manifest_path "actions/manifest.json"

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    on_exit(&restore_actions_config/0)

    project = insert_project("actions")
    owner = seed_user("actions-owner@example.com", "Owner")
    owner_membership = insert_membership(project, owner, :owner)
    viewer = seed_user("actions-viewer@example.com", "Viewer")
    viewer_membership = insert_membership(project, viewer, :viewer)

    %{
      project: project,
      owner: owner_membership,
      viewer: viewer_membership
    }
  end

  describe "list/3" do
    test "an owner and a viewer can list a node's actions", %{
      project: project,
      owner: owner,
      viewer: viewer
    } do
      node = insert_node(project, %{@manifest_path => valid_manifest()})

      assert {:ok, manifest} = Actions.list(project, node, owner)
      assert Enum.map(manifest.actions, & &1.name) == ["run_analysis"]

      assert {:ok, %{actions: [_action]}} = Actions.list(project, node, viewer)
    end

    test "anonymous visitors are forbidden before the store is read", %{
      project: project
    } do
      node = insert_node(project, %{@manifest_path => valid_manifest()})

      assert Actions.list(project, node, nil) == {:error, :forbidden}
    end

    test "a membership from another project is forbidden", %{project: project} do
      other = insert_project("actions-other")

      other_owner =
        other
        |> insert_membership(seed_user("actions-other-owner@example.com", "Other"), :owner)

      node = insert_node(project, %{@manifest_path => valid_manifest()})

      assert Actions.list(project, node, other_owner) == {:error, :forbidden}
    end

    test "a commit that is not in the store is not found", %{project: project, owner: owner} do
      node = insert_node(project, %{@manifest_path => valid_manifest()})
      missing = %{node | git_commit_sha: String.duplicate("0", 40)}

      assert Actions.list(project, missing, owner) == {:error, :not_found}
    end

    test "a manifest path that is a directory is not found", %{project: project, owner: owner} do
      node =
        insert_node(project, %{"actions/manifest.json/inside.txt" => "not a manifest"})

      assert Actions.list(project, node, owner) == {:error, :not_found}
    end

    test "a node from another project is not found", %{project: project, owner: owner} do
      other = insert_project("other-actions")
      node = insert_node(other, %{@manifest_path => valid_manifest()})

      assert Actions.list(project, node, owner) == {:error, :not_found}
      assert Actions.list(project, nil, owner) == {:error, :not_found}
    end

    test "a snapshot without a manifest is not found", %{project: project, owner: owner} do
      node = insert_node(project, %{"README.md" => "# Hello\n"})

      assert Actions.list(project, node, owner) == {:error, :not_found}
    end

    test "a malformed manifest is a shape-only error", %{project: project, owner: owner} do
      node = insert_node(project, %{@manifest_path => "{not json"})

      assert Actions.list(project, node, owner) == {:error, :invalid_json}
    end

    test "an oversized manifest is rejected", %{project: project, owner: owner} do
      Application.put_env(:cadence_server, :actions_max_manifest_bytes, 10)
      node = insert_node(project, %{@manifest_path => valid_manifest()})

      assert Actions.list(project, node, owner) == {:error, :too_large}
    end

    test "the deployment switch disables the layer", %{project: project, owner: owner} do
      Application.put_env(:cadence_server, :actions_enabled, false)
      node = insert_node(project, %{@manifest_path => valid_manifest()})

      assert Actions.list(project, node, owner) == {:error, :disabled}
    end
  end

  defp valid_manifest do
    Jason.encode!(%{
      "actions" => [
        %{
          "name" => "run_analysis",
          "command" => "python actions/run.py",
          "description" => "Run the analysis",
          "expose" => true
        }
      ]
    })
  end

  defp insert_project(slug) do
    %Project{}
    |> Project.changeset(%{
      name: String.capitalize(slug),
      slug: slug,
      owner_id: Ecto.UUID.generate()
    })
    |> Repo.insert!()
  end

  defp insert_node(project, files) do
    %Node{}
    |> Node.changeset(%{
      project_id: project.id,
      git_commit_sha: snapshot(project, files),
      created_by: project.owner_id,
      created_at: DateTime.utc_now(),
      docs_state: :pending,
      flags: [:"in-progress"],
      message: "node"
    })
    |> Repo.insert!()
  end

  defp snapshot(project, files) do
    repo = ProjectGit.init(project.id)
    {:ok, tree} = GitStore.put_files(repo, files)
    GitStore.write_commit(repo, tree, [], %{name: "test", email: "test@example.com"}, "snapshot")
  end

  defp seed_user(email, name), do: Ash.Seed.seed!(User, %{email: email, name: name})

  defp insert_membership(project, user, role) do
    %Membership{}
    |> Membership.changeset(%{user_id: user.id, project_id: project.id, role: role})
    |> Repo.insert!()
  end

  defp restore_actions_config do
    Application.delete_env(:cadence_server, :actions_enabled)
    Application.delete_env(:cadence_server, :actions_max_manifest_bytes)
  end
end
