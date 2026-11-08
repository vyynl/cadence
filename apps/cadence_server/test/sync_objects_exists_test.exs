defmodule Cadence.ServerWeb.SyncObjectsExistsTest do
  use Cadence.ServerWeb.ConnCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Cadence.Server.{Accounts, ProjectGit, Repo}
  alias Cadence.Server.Accounts.User
  alias Cadence.Shared.{GitStore, Membership, Node, Project}

  @author %{name: "Exists Test", email: "exists@example.com"}

  setup do
    user = seed_user("owner")
    project = insert_project(user)
    insert_membership(user, project, :owner)
    {:ok, api_key} = Accounts.create_api_key(user, "exists-test")

    on_exit(fn -> File.rm_rf!(ProjectGit.path(project.id)) end)

    %{
      user: user,
      project: project,
      plaintext: api_key.__metadata__.plaintext_api_key
    }
  end

  describe "POST /sync/objects/exists" do
    test "reports present loose objects and omits absent ones", %{
      conn: conn,
      project: project,
      plaintext: plaintext
    } do
      {_store, %{commit: commit, tree: tree, objects: objects}} = snapshot(project)
      missing = String.duplicate("0", 40)

      assert %{"present" => present} =
               conn
               |> authed(plaintext)
               |> post_json("/sync/objects/exists", %{
                 "project_id" => project.id,
                 "shas" => [commit, missing, tree]
               })
               |> json_response(200)

      assert present == [commit, tree]
      assert length(objects) >= 3
    end

    test "dedupes the request and preserves first-seen order", %{
      conn: conn,
      project: project,
      plaintext: plaintext
    } do
      {_store, %{commit: commit, tree: tree}} = snapshot(project)

      assert %{"present" => present} =
               conn
               |> authed(plaintext)
               |> post_json("/sync/objects/exists", %{
                 "project_id" => project.id,
                 "shas" => [tree, commit, tree, commit]
               })
               |> json_response(200)

      assert present == [tree, commit]
    end

    test "answers from the pack index when the loose copy is gone", %{
      conn: conn,
      project: project,
      plaintext: plaintext
    } do
      {store, %{commit: commit, tree: tree, objects: objects}} = snapshot(project)

      assert {:ok, _info} = GitStore.pack_objects(store, objects)
      remove_loose!(store, Enum.map(objects, & &1.sha))

      refute File.regular?(loose_path(store, commit))
      assert {:ok, _objects} = GitStore.read_raw(store, commit)

      assert %{"present" => present} =
               conn
               |> authed(plaintext)
               |> post_json("/sync/objects/exists", %{
                 "project_id" => project.id,
                 "shas" => [commit, tree]
               })
               |> json_response(200)

      assert present == [commit, tree]
    end

    test "refuses malformed or oversized requests", %{
      conn: conn,
      project: project,
      plaintext: plaintext
    } do
      previous = Application.get_env(:cadence_server, :sync_exists_limit)
      Application.put_env(:cadence_server, :sync_exists_limit, 1)
      on_exit(fn -> restore_env(:sync_exists_limit, previous) end)

      malformed =
        conn
        |> authed(plaintext)
        |> post_json("/sync/objects/exists", %{
          "project_id" => project.id,
          "shas" => ["not-a-sha"]
        })
        |> json_response(422)

      assert malformed["error"] == "invalid object sha"

      oversized =
        conn
        |> authed(plaintext)
        |> post_json("/sync/objects/exists", %{
          "project_id" => project.id,
          "shas" => [String.duplicate("a", 40), String.duplicate("b", 40)]
        })
        |> json_response(422)

      assert oversized["error"] == "too many object shas"

      # The raw length is capped before deduplication, so a duplicate-only
      # payload cannot bypass the bound.
      duplicate = String.duplicate("c", 40)

      duplicates =
        conn
        |> authed(plaintext)
        |> post_json("/sync/objects/exists", %{
          "project_id" => project.id,
          "shas" => [duplicate, duplicate]
        })
        |> json_response(422)

      assert duplicates["error"] == "too many object shas"

      not_a_list =
        conn
        |> authed(plaintext)
        |> post_json("/sync/objects/exists", %{"project_id" => project.id, "shas" => "abc"})
        |> json_response(422)

      assert not_a_list["error"] == "invalid sync payload"
    end

    test "requires a writable project role", %{project: project} do
      viewer = seed_user("viewer")
      insert_membership(viewer, project, :viewer)
      {:ok, viewer_key} = Accounts.create_api_key(viewer, "viewer")
      viewer_plaintext = viewer_key.__metadata__.plaintext_api_key

      assert %{"error" => "not a project member"} =
               authed_conn(viewer_plaintext)
               |> post_json("/sync/objects/exists", %{
                 "project_id" => project.id,
                 "shas" => [String.duplicate("a", 40)]
               })
               |> json_response(403)
    end

    test "returns 404 for an unknown project and 403 for a non-member", %{
      conn: conn,
      project: project
    } do
      stranger = seed_user("stranger")
      {:ok, stranger_key} = Accounts.create_api_key(stranger, "stranger")
      plaintext = stranger_key.__metadata__.plaintext_api_key

      assert %{"error" => "project not found"} =
               conn
               |> authed(plaintext)
               |> post_json("/sync/objects/exists", %{
                 "project_id" => Ecto.UUID.generate(),
                 "shas" => []
               })
               |> json_response(404)

      assert %{"error" => "not a project member"} =
               authed_conn(plaintext)
               |> post_json("/sync/objects/exists", %{
                 "project_id" => project.id,
                 "shas" => []
               })
               |> json_response(403)
    end

    test "rejects an unauthenticated request", %{conn: conn} do
      conn
      |> put_req_header("accept", "application/json")
      |> post_json("/sync/objects/exists", %{"project_id" => Ecto.UUID.generate(), "shas" => []})
      |> json_response(401)
    end
  end

  describe "push without objects" do
    test "a new node id may reuse objects already in the store", %{
      conn: conn,
      project: project,
      plaintext: plaintext
    } do
      {_store, %{commit: commit}} = snapshot(project)
      node_id = Ecto.UUID.generate()

      assert %{"mappings" => [%{"cloud_id" => ^node_id}]} =
               conn
               |> authed(plaintext)
               |> post_json("/sync/nodes", %{
                 "nodes" => [node_payload(project, node_id, commit, [], [])]
               })
               |> json_response(200)

      assert %Node{git_commit_sha: ^commit} = Repo.get!(Node, node_id)
    end

    test "a commit missing from the store is still refused", %{
      conn: conn,
      project: project,
      plaintext: plaintext
    } do
      # A valid-looking SHA that was never imported.
      missing = String.duplicate("f", 40)

      assert %{"error" => "commit object missing from push", "failed_local_id" => local_id} =
               conn
               |> authed(plaintext)
               |> post_json("/sync/nodes", %{
                 "nodes" => [
                   node_payload(project, Ecto.UUID.generate(), missing, [], [])
                 ]
               })
               |> json_response(422)

      assert is_binary(local_id)
      assert Repo.aggregate(Node, :count, :id) == 0
    end
  end

  ## Helpers

  defp authed_conn(plaintext) do
    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{plaintext}")
  end

  defp authed(conn, plaintext), do: put_req_header(conn, "authorization", "Bearer #{plaintext}")

  defp post_json(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp snapshot(project) do
    dir = tmp_dir()
    store = ProjectGit.init(project.id)

    Enum.each(
      %{
        "README.md" => "# Exists\n",
        "src/app.txt" => "app\n"
      },
      fn {path, content} ->
        full = Path.join(dir, path)
        File.mkdir_p!(Path.dirname(full))
        File.write!(full, content)
      end
    )

    tree = GitStore.build_tree(store, dir)
    commit = GitStore.write_commit(store, tree, [], @author, "exists")
    {:ok, objects} = GitStore.objects_from(store, commit)

    {store, %{commit: commit, tree: tree, objects: objects}}
  end

  defp loose_path(store, sha) do
    Path.join([store.home_dir, "objects", String.slice(sha, 0, 2), String.slice(sha, 2, 38)])
  end

  defp remove_loose!(store, shas) do
    Enum.each(shas, fn sha -> File.rm!(loose_path(store, sha)) end)
  end

  defp seed_user(label) do
    Ash.Seed.seed!(User, %{
      email: "exists-#{label}-#{System.unique_integer([:positive])}@example.com",
      name: label
    })
  end

  defp insert_project(user) do
    %Project{}
    |> Project.changeset(%{
      name: "Exists",
      slug: "exists-#{System.unique_integer([:positive])}",
      owner_id: user.id
    })
    |> Repo.insert!()
  end

  defp insert_membership(user, project, role) do
    %Membership{}
    |> Membership.changeset(%{
      user_id: user.id,
      project_id: project.id,
      role: role
    })
    |> Repo.insert!()
  end

  defp node_payload(project, local_id, commit, parents, objects) do
    %{
      "local_id" => local_id,
      "git_objects" => objects,
      "metadata" => %{
        "project_id" => project.id,
        "git_commit_sha" => commit,
        "parents" => parents,
        "flags" => ["in-progress"],
        "pinned" => false,
        "message" => "node",
        "session_metadata" => %{},
        "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "docs_state" => "pending"
      }
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:cadence_server, key)
  defp restore_env(key, value), do: Application.put_env(:cadence_server, key, value)

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "cadence_exists_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
