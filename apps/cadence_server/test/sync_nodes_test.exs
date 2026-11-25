defmodule Cadence.ServerWeb.SyncNodesTest do
  use Cadence.ServerWeb.ConnCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  import Ecto.Query

  alias Cadence.Server.{Accounts, Incident, Incidents, Portfolio, ProjectGit, Repo}
  alias Cadence.Server.Accounts.User
  alias Cadence.Shared.{GitStore, Membership, Node, Project}

  @author %{name: "Sync Test", email: "sync@example.com"}
  @secret "ghp_abcdefghijklmnopqrstuvwxyz0123456789"

  setup do
    user = seed_user("owner")
    project = insert_project(user)
    insert_membership(user, project, :owner)
    {:ok, api_key} = Accounts.create_api_key(user, "sync-test")

    on_exit(fn -> File.rm_rf!(ProjectGit.path(project.id)) end)

    %{
      user: user,
      project: project,
      plaintext: api_key.__metadata__.plaintext_api_key
    }
  end

  test "push then pull round-trips a DAG into a clean object store", %{
    conn: conn,
    user: user,
    project: project,
    plaintext: plaintext
  } do
    dag = build_dag(tmp_dir())

    payload = %{
      "nodes" => [
        node_payload(project, dag.root_id, dag.root, [], dag.repo, "root"),
        node_payload(project, dag.child_id, dag.child, [dag.root_id], dag.repo, "child"),
        node_payload(project, dag.sibling_id, dag.sibling, [dag.root_id], dag.repo, "sibling")
      ]
    }

    push =
      conn
      |> authed(plaintext)
      |> post_json("/sync/nodes", payload)

    assert %{"mappings" => mappings} = json_response(push, 200)
    assert length(mappings) == 3

    assert Enum.all?(mappings, fn mapping ->
             mapping["local_id"] == mapping["cloud_id"]
           end)

    pull = authed_conn(plaintext) |> get("/sync/nodes?project_id=#{project.id}")

    assert %{"nodes" => nodes, "cursor" => cursor} = json_response(pull, 200)
    assert is_binary(cursor)
    assert length(nodes) == 3

    assert Enum.sort(Enum.map(nodes, & &1["id"])) ==
             Enum.sort([dag.root_id, dag.child_id, dag.sibling_id])

    assert Enum.all?(nodes, &(&1["created_by"] == user.id))
    assert Enum.all?(nodes, &(&1["flags"] == ["in-progress"]))
    assert Enum.all?(nodes, &(&1["docs_state"] == "pending"))

    target = GitStore.init(Path.join(tmp_dir(), "target"), bare: true)

    Enum.each(nodes, fn node ->
      assert :ok = GitStore.import_objects(target, decode_objects(node["git_objects"]))
    end)

    assert GitStore.read_commit(target, dag.root).tree == dag.root_tree
    assert GitStore.read_commit(target, dag.child).tree == dag.child_tree
    assert GitStore.read_commit(target, dag.sibling).tree == dag.sibling_tree

    checkout = Path.join(tmp_dir(), "checkout")
    :ok = GitStore.checkout(target, dag.child, checkout)
    assert File.read!(Path.join(checkout, "README.md")) == "# Child\n"
  end

  test "a successful push asks the repacker to check the project", %{
    conn: conn,
    project: project,
    plaintext: plaintext
  } do
    parent = self()
    previous = Application.get_env(:cadence_server, :repack_runner)

    Application.put_env(:cadence_server, :repack_runner, fn id ->
      send(parent, {:repack, id})
    end)

    on_exit(fn -> restore_env(:repack_runner, previous) end)

    dag = build_dag(tmp_dir())

    payload = %{
      "nodes" => [node_payload(project, dag.root_id, dag.root, [], dag.repo, "root")]
    }

    push = conn |> authed(plaintext) |> post_json("/sync/nodes", payload)
    assert %{"mappings" => [_mapping]} = json_response(push, 200)

    assert_receive {:repack, project_id}, 1_000
    assert project_id == project.id
  end

  test "retrying the same push is idempotent", %{
    conn: conn,
    project: project,
    plaintext: plaintext
  } do
    dag = build_dag(tmp_dir())

    payload = %{
      "nodes" => [
        node_payload(project, dag.root_id, dag.root, [], dag.repo, "root"),
        node_payload(project, dag.child_id, dag.child, [dag.root_id], dag.repo, "child")
      ]
    }

    first = conn |> authed(plaintext) |> post_json("/sync/nodes", payload)
    assert %{"mappings" => first_mappings} = json_response(first, 200)

    second =
      authed_conn(plaintext)
      |> post_json("/sync/nodes", payload)

    assert %{"mappings" => second_mappings} = json_response(second, 200)
    assert first_mappings == second_mappings
    assert Repo.aggregate(Node, :count, :id) == 2
  end

  test "pull paginates with the seq cursor", %{
    conn: conn,
    project: project,
    plaintext: plaintext
  } do
    previous = Application.get_env(:cadence_server, :sync_pull_limit)
    Application.put_env(:cadence_server, :sync_pull_limit, 2)
    on_exit(fn -> Application.put_env(:cadence_server, :sync_pull_limit, previous) end)

    dag = build_dag(tmp_dir())

    payload = %{
      "nodes" => [
        node_payload(project, dag.root_id, dag.root, [], dag.repo, "root"),
        node_payload(project, dag.child_id, dag.child, [dag.root_id], dag.repo, "child"),
        node_payload(project, dag.sibling_id, dag.sibling, [dag.root_id], dag.repo, "sibling")
      ]
    }

    assert %{"mappings" => _mappings} =
             conn
             |> authed(plaintext)
             |> post_json("/sync/nodes", payload)
             |> json_response(200)

    first = authed_conn(plaintext) |> get("/sync/nodes?project_id=#{project.id}")
    assert %{"nodes" => first_nodes, "cursor" => first_cursor} = json_response(first, 200)
    assert length(first_nodes) == 2

    second =
      authed_conn(plaintext)
      |> get("/sync/nodes?project_id=#{project.id}&since=#{first_cursor}")

    assert %{"nodes" => second_nodes, "cursor" => second_cursor} = json_response(second, 200)
    assert length(second_nodes) == 1
    refute Enum.any?(second_nodes, &(&1["id"] in Enum.map(first_nodes, fn n -> n["id"] end)))
    assert second_cursor != first_cursor
  end

  test "viewers and non-members cannot push or pull", %{
    conn: _conn,
    project: project,
    plaintext: plaintext
  } do
    viewer = seed_user("viewer")
    insert_membership(viewer, project, :viewer)
    {:ok, viewer_key} = Accounts.create_api_key(viewer, "viewer")

    outsider = seed_user("outsider")
    {:ok, outsider_key} = Accounts.create_api_key(outsider, "outsider")

    dag = build_dag(tmp_dir())
    payload = %{"nodes" => [node_payload(project, dag.root_id, dag.root, [], dag.repo, "root")]}

    for key <- [viewer_key, outsider_key] do
      plaintext = key.__metadata__.plaintext_api_key

      assert %{"error" => _} =
               authed_conn(plaintext)
               |> post_json("/sync/nodes", payload)
               |> json_response(403)

      assert %{"error" => _} =
               authed_conn(plaintext)
               |> get("/sync/nodes?project_id=#{project.id}")
               |> json_response(403)
    end

    assert %{"error" => "unauthorized"} =
             authed_conn(plaintext)
             |> put_req_header("authorization", "Bearer nope")
             |> post_json("/sync/nodes", payload)
             |> json_response(401)
  end

  test "rejects mixed projects and unknown parents", %{
    conn: conn,
    user: user,
    project: project,
    plaintext: plaintext
  } do
    other_project = insert_project(user, "other")
    insert_membership(user, other_project, :owner)
    dag = build_dag(tmp_dir())
    Phoenix.PubSub.subscribe(Cadence.Server.PubSub, "sync:user:#{user.id}")

    mixed = %{
      "nodes" => [
        node_payload(project, dag.root_id, dag.root, [], dag.repo, "root"),
        node_payload(other_project, dag.child_id, dag.child, [dag.root_id], dag.repo, "child")
      ]
    }

    mixed_response =
      conn
      |> authed(plaintext)
      |> post_json("/sync/nodes", mixed)
      |> json_response(422)

    assert %{"error" => _} = mixed_response
    refute Map.has_key?(mixed_response, "failed_local_id")

    unknown_parent = %{
      "nodes" => [
        node_payload(project, dag.child_id, dag.child, [Ecto.UUID.generate()], dag.repo, "child")
      ]
    }

    assert %{"error" => _, "failed_local_id" => failed_local_id} =
             authed_conn(plaintext)
             |> post_json("/sync/nodes", unknown_parent)
             |> json_response(422)

    assert failed_local_id == dag.child_id
    refute_receive {:sync_available, _project_id}, 100
  end

  test "rejects duplicate IDs, conflicting nodes, and tampered objects", %{
    conn: conn,
    project: project,
    plaintext: plaintext
  } do
    dag = build_dag(tmp_dir())
    root = node_payload(project, dag.root_id, dag.root, [], dag.repo, "root")

    duplicate = %{"nodes" => [root, root]}

    duplicate_response =
      conn
      |> authed(plaintext)
      |> post_json("/sync/nodes", duplicate)
      |> json_response(409)

    assert %{"error" => _} = duplicate_response
    refute Map.has_key?(duplicate_response, "failed_local_id")

    assert %{"mappings" => _} =
             authed_conn(plaintext)
             |> post_json("/sync/nodes", %{"nodes" => [root]})
             |> json_response(200)

    conflicting =
      node_payload(project, dag.root_id, dag.child, [], dag.repo, "conflict")

    assert %{"error" => _, "failed_local_id" => root_conflict_id} =
             authed_conn(plaintext)
             |> post_json("/sync/nodes", %{"nodes" => [conflicting]})
             |> json_response(409)

    assert root_conflict_id == dag.root_id

    tampered = node_payload(project, dag.child_id, dag.child, [dag.root_id], dag.repo, "child")
    [object | rest] = tampered["git_objects"]

    tampered =
      put_in(tampered, ["git_objects"], [%{object | "data" => object["data"] <> "x"} | rest])

    assert %{"error" => _, "failed_local_id" => tampered_id} =
             authed_conn(plaintext)
             |> post_json("/sync/nodes", %{"nodes" => [tampered]})
             |> json_response(422)

    assert tampered_id == dag.child_id
  end

  test "node-level metadata errors include the failed local ID", %{
    project: project,
    plaintext: plaintext
  } do
    dag = build_dag(tmp_dir())

    invalid =
      project
      |> node_payload(dag.root_id, dag.root, [], dag.repo, "root")
      |> put_in(["metadata", "flags"], ["not-a-flag"])

    assert %{"error" => "invalid flag", "failed_local_id" => failed_local_id} =
             authed_conn(plaintext)
             |> post_json("/sync/nodes", %{"nodes" => [invalid]})
             |> json_response(422)

    assert failed_local_id == dag.root_id
  end

  test "rejects unknown projects and invalid cursors", %{project: project, plaintext: plaintext} do
    assert %{"error" => "project not found"} =
             authed_conn(plaintext)
             |> get("/sync/nodes?project_id=#{Ecto.UUID.generate()}")
             |> json_response(404)

    assert %{"error" => "invalid cursor"} =
             authed_conn(plaintext)
             |> get("/sync/nodes?project_id=#{project.id}&since=nope")
             |> json_response(400)
  end

  test "reports a corrupt/missing server object store as 500", %{
    conn: conn,
    project: project,
    plaintext: plaintext
  } do
    dag = build_dag(tmp_dir())
    payload = %{"nodes" => [node_payload(project, dag.root_id, dag.root, [], dag.repo, "root")]}

    assert %{"mappings" => _} =
             conn
             |> authed(plaintext)
             |> post_json("/sync/nodes", payload)
             |> json_response(200)

    <<dir::binary-size(2)>> <> rest = dag.root
    File.rm!(Path.join([ProjectGit.path(project.id), "objects", dir, rest]))

    assert %{"error" => "server object store is incomplete"} =
             authed_conn(plaintext)
             |> get("/sync/nodes?project_id=#{project.id}")
             |> json_response(500)
  end

  test "broadcasts successful pushes to every member's daemon", %{
    conn: conn,
    user: user,
    project: project,
    plaintext: plaintext
  } do
    project_id = project.id
    member = seed_user("member")
    insert_membership(member, project, :viewer)

    Phoenix.PubSub.subscribe(Cadence.Server.PubSub, "project:#{project_id}")
    subscribe_as(user.id)
    subscribe_as(member.id)

    dag = build_dag(tmp_dir())

    payload = %{"nodes" => [node_payload(project, dag.root_id, dag.root, [], dag.repo, "root")]}

    assert %{"mappings" => [%{"cloud_id" => cloud_id}]} =
             conn
             |> authed(plaintext)
             |> post_json("/sync/nodes", payload)
             |> json_response(200)

    assert_receive {:nodes_pushed, ^project_id, [^cloud_id]}
    # The fan-out has no ordering guarantee: two members (or two daemons for
    # one member) can publish in either order. Compare the recipient set.
    assert_receive {first_id, {:sync_available, ^project_id}}
    assert_receive {second_id, {:sync_available, ^project_id}}
    assert MapSet.new([first_id, second_id]) == MapSet.new([user.id, member.id])
    refute_receive {_user_id, {:sync_available, _project_id}}
  end

  test "pinning a node bumps the cursor and redelivers it on the next pull", %{
    conn: conn,
    user: user,
    project: project,
    plaintext: plaintext
  } do
    dag = build_dag(tmp_dir())

    payload = %{"nodes" => [node_payload(project, dag.root_id, dag.root, [], dag.repo, "root")]}

    assert %{"mappings" => _mappings} =
             conn
             |> authed(plaintext)
             |> post_json("/sync/nodes", payload)
             |> json_response(200)

    pulled = authed_conn(plaintext) |> get("/sync/nodes?project_id=#{project.id}")
    assert %{"nodes" => [%{"pinned" => false}], "cursor" => cursor} = json_response(pulled, 200)

    Phoenix.PubSub.subscribe(Cadence.Server.PubSub, "sync:user:#{user.id}")

    assert {:ok, %{pinned: true}} =
             Cadence.Server.ProjectAdmin.set_pinned(project.id, dag.root_id, true)

    assert_receive {:sync_available, project_id}
    assert project_id == project.id

    again =
      authed_conn(plaintext)
      |> get("/sync/nodes?project_id=#{project.id}&since=#{cursor}")

    assert %{"nodes" => [node], "cursor" => next_cursor} = json_response(again, 200)
    assert node["id"] == dag.root_id
    assert node["pinned"] == true
    assert next_cursor != cursor
  end

  describe "push scan" do
    test "pushing a snapshot with a secret returns 200 and quarantines the node", %{
      project: project,
      plaintext: plaintext
    } do
      dir = tmp_dir()

      {repo, commit} =
        snapshot_with(dir, "secret", %{
          "README.md" => "# Secret\n",
          "config.txt" => "token: #{@secret}\n"
        })

      node_id = Ecto.UUID.generate()

      push =
        authed_conn(plaintext)
        |> post_json("/sync/nodes", %{
          "nodes" => [node_payload(project, node_id, commit, [], repo, "secret")]
        })

      assert %{"mappings" => [%{"cloud_id" => ^node_id}]} = json_response(push, 200)

      assert [incident] = open_node_incidents(project)
      assert incident.kind == :secret_detected
      assert incident.severity == :critical
      assert incident.node_id == node_id
      assert incident.details["stage"] == "push_scan"
      assert Incidents.blocking_node?(project.id, node_id)
      assert Portfolio.quarantine_status(project, Repo.get!(Node, node_id)) == :quarantined
      refute inspect(incident.details) =~ @secret
    end

    test "a clean push opens no incident", %{project: project, plaintext: plaintext} do
      {repo, commit} =
        snapshot_with(tmp_dir(), "clean", %{
          "README.md" => "# Clean\n",
          "src/app.ex" => "defmodule App do\nend\n"
        })

      node_id = Ecto.UUID.generate()

      assert %{"mappings" => [%{"cloud_id" => ^node_id}]} =
               authed_conn(plaintext)
               |> post_json("/sync/nodes", %{
                 "nodes" => [node_payload(project, node_id, commit, [], repo, "clean")]
               })
               |> json_response(200)

      assert open_node_incidents(project) == []
      refute Incidents.blocking_node?(project.id, node_id)
    end

    test "a capped scan still returns 200 and quarantines the node", %{
      project: project,
      plaintext: plaintext
    } do
      previous = Application.get_env(:cadence_server, :scan_max_files)
      Application.put_env(:cadence_server, :scan_max_files, 1)
      on_exit(fn -> restore_env(:scan_max_files, previous) end)

      {repo, commit} =
        snapshot_with(tmp_dir(), "two-files", %{
          "README.md" => "# Clean\n",
          "src/a.txt" => "a\n"
        })

      node_id = Ecto.UUID.generate()

      assert %{"mappings" => [%{"cloud_id" => ^node_id}]} =
               authed_conn(plaintext)
               |> post_json("/sync/nodes", %{
                 "nodes" => [node_payload(project, node_id, commit, [], repo, "clean")]
               })
               |> json_response(200)

      assert [incident] = open_node_incidents(project)
      assert incident.kind == :scan_incomplete
      assert incident.severity == :critical
      assert incident.details["reason"] == "too_many_files"
      assert Incidents.blocking_node?(project.id, node_id)
    end

    test "a mixed batch maps both nodes but only incidents the risky one", %{
      project: project,
      plaintext: plaintext
    } do
      dir = tmp_dir()
      repo = GitStore.init(Path.join(dir, "origin"), bare: true)

      clean = snapshot_in(repo, dir, "clean", %{"README.md" => "# Clean\n"})
      secret = snapshot_in(repo, dir, "secret", %{"config.txt" => "token: #{@secret}\n"})

      clean_id = Ecto.UUID.generate()
      secret_id = Ecto.UUID.generate()

      push =
        authed_conn(plaintext)
        |> post_json("/sync/nodes", %{
          "nodes" => [
            node_payload(project, clean_id, clean, [], repo, "clean"),
            node_payload(project, secret_id, secret, [], repo, "secret")
          ]
        })

      assert %{"mappings" => mappings} = json_response(push, 200)
      assert Enum.map(mappings, & &1["cloud_id"]) == [clean_id, secret_id]

      assert [incident] = open_node_incidents(project)
      assert incident.node_id == secret_id
      refute Incidents.blocking_node?(project.id, clean_id)
      assert Incidents.blocking_node?(project.id, secret_id)
    end

    test "retrying the same push keeps mappings and a single incident", %{
      project: project,
      plaintext: plaintext
    } do
      {repo, commit} =
        snapshot_with(tmp_dir(), "secret", %{"config.txt" => "token: #{@secret}\n"})

      node_id = Ecto.UUID.generate()

      payload = %{"nodes" => [node_payload(project, node_id, commit, [], repo, "secret")]}

      assert %{"mappings" => first_mappings} =
               authed_conn(plaintext)
               |> post_json("/sync/nodes", payload)
               |> json_response(200)

      assert %{"mappings" => second_mappings} =
               authed_conn(plaintext)
               |> post_json("/sync/nodes", payload)
               |> json_response(200)

      assert first_mappings == second_mappings
      assert [incident] = open_node_incidents(project)
      assert incident.node_id == node_id
      assert Repo.aggregate(Incident, :count) == 1
    end
  end

  describe "imported merges (Phase 9c)" do
    test "an owner may push an imported merge node with multiple parents", %{
      conn: conn,
      project: project,
      plaintext: plaintext
    } do
      dag = build_merge_dag(tmp_dir())

      payload = %{
        "nodes" => [
          node_payload(project, dag.root_id, dag.root, [], dag.repo, "root"),
          node_payload(project, dag.left_id, dag.left, [dag.root_id], dag.repo, "left"),
          node_payload(project, dag.right_id, dag.right, [dag.root_id], dag.repo, "right"),
          imported(
            node_payload(
              project,
              dag.merge_id,
              dag.merge,
              [dag.left_id, dag.right_id],
              dag.repo,
              "merge"
            )
          )
        ]
      }

      assert %{"mappings" => mappings} =
               conn
               |> authed(plaintext)
               |> post_json("/sync/nodes", payload)
               |> json_response(200)

      assert length(mappings) == 4
      assert Repo.get!(Node, dag.merge_id).parents == [dag.left_id, dag.right_id]
    end

    test "an ordinary owner push still refuses a second parent", %{
      project: project,
      plaintext: plaintext
    } do
      dag = build_merge_dag(tmp_dir())

      payload = %{
        "nodes" => [
          node_payload(project, dag.root_id, dag.root, [], dag.repo, "root"),
          node_payload(project, dag.left_id, dag.left, [dag.root_id], dag.repo, "left"),
          node_payload(project, dag.right_id, dag.right, [dag.root_id], dag.repo, "right"),
          node_payload(
            project,
            dag.merge_id,
            dag.merge,
            [dag.left_id, dag.right_id],
            dag.repo,
            "merge"
          )
        ]
      }

      assert %{
               "error" => "pushed nodes may have at most one parent",
               "failed_local_id" => failed_local_id
             } =
               authed_conn(plaintext)
               |> post_json("/sync/nodes", payload)
               |> json_response(422)

      assert failed_local_id == dag.merge_id
      assert Repo.get(Node, dag.merge_id) == nil
    end

    test "a trusted member cannot push an imported merge", %{
      project: project
    } do
      trusted = seed_user("trusted")
      insert_membership(trusted, project, :trusted)
      {:ok, trusted_key} = Accounts.create_api_key(trusted, "trusted-sync")
      plaintext = trusted_key.__metadata__.plaintext_api_key

      dag = build_merge_dag(tmp_dir())

      payload = %{
        "nodes" => [
          node_payload(project, dag.root_id, dag.root, [], dag.repo, "root"),
          node_payload(project, dag.left_id, dag.left, [dag.root_id], dag.repo, "left"),
          node_payload(project, dag.right_id, dag.right, [dag.root_id], dag.repo, "right"),
          imported(
            node_payload(
              project,
              dag.merge_id,
              dag.merge,
              [dag.left_id, dag.right_id],
              dag.repo,
              "merge"
            )
          )
        ]
      }

      assert %{"failed_local_id" => failed_local_id} =
               authed_conn(plaintext)
               |> post_json("/sync/nodes", payload)
               |> json_response(422)

      assert failed_local_id == dag.merge_id
      assert Repo.get(Node, dag.merge_id) == nil
    end

    test "an imported merge above the configured cap is refused", %{
      project: project,
      plaintext: plaintext
    } do
      previous = Application.get_env(:cadence_server, :sync_max_push_parents)
      Application.put_env(:cadence_server, :sync_max_push_parents, 2)
      on_exit(fn -> restore_env(:sync_max_push_parents, previous) end)

      dag = build_merge_dag(tmp_dir())

      payload = %{
        "nodes" => [
          node_payload(project, dag.root_id, dag.root, [], dag.repo, "root"),
          node_payload(project, dag.left_id, dag.left, [dag.root_id], dag.repo, "left"),
          node_payload(project, dag.right_id, dag.right, [dag.root_id], dag.repo, "right"),
          node_payload(project, dag.third_id, dag.third, [dag.root_id], dag.repo, "third"),
          imported(
            node_payload(
              project,
              dag.octopus_id,
              dag.octopus,
              [dag.left_id, dag.right_id, dag.third_id],
              dag.repo,
              "octopus"
            )
          )
        ]
      }

      assert %{"error" => "pushed node exceeds the parent limit", "failed_local_id" => id} =
               authed_conn(plaintext)
               |> post_json("/sync/nodes", payload)
               |> json_response(422)

      assert id == dag.octopus_id
    end

    test "a parent from another project is refused", %{
      project: project,
      user: user,
      plaintext: plaintext
    } do
      other_project = insert_project(user, "merge-other")
      insert_membership(user, other_project, :owner)

      foreign =
        %Node{}
        |> Node.changeset(%{
          project_id: other_project.id,
          git_commit_sha: String.duplicate("d", 40),
          parents: [],
          flags: [],
          created_by: user.id,
          created_at: DateTime.utc_now(),
          docs_state: :skipped
        })
        |> Repo.insert!()

      dag = build_merge_dag(tmp_dir())

      payload = %{
        "nodes" => [
          node_payload(project, dag.root_id, dag.root, [], dag.repo, "root"),
          node_payload(project, dag.left_id, dag.left, [dag.root_id], dag.repo, "left"),
          imported(
            node_payload(
              project,
              dag.merge_id,
              dag.merge,
              [dag.left_id, foreign.id],
              dag.repo,
              "merge"
            )
          )
        ]
      }

      assert %{"error" => "parent node does not exist (parents-first ordering required)"} =
               authed_conn(plaintext)
               |> post_json("/sync/nodes", payload)
               |> json_response(422)
    end

    test "re-pushing an existing imported merge stays idempotent when the cap is lowered", %{
      conn: conn,
      project: project,
      plaintext: plaintext
    } do
      dag = build_merge_dag(tmp_dir())

      payload = %{
        "nodes" => [
          node_payload(project, dag.root_id, dag.root, [], dag.repo, "root"),
          node_payload(project, dag.left_id, dag.left, [dag.root_id], dag.repo, "left"),
          node_payload(project, dag.right_id, dag.right, [dag.root_id], dag.repo, "right"),
          imported(
            node_payload(
              project,
              dag.merge_id,
              dag.merge,
              [dag.left_id, dag.right_id],
              dag.repo,
              "merge"
            )
          )
        ]
      }

      assert %{"mappings" => first} =
               conn
               |> authed(plaintext)
               |> post_json("/sync/nodes", payload)
               |> json_response(200)

      previous = Application.get_env(:cadence_server, :sync_max_push_parents)
      Application.put_env(:cadence_server, :sync_max_push_parents, 1)
      on_exit(fn -> restore_env(:sync_max_push_parents, previous) end)

      assert %{"mappings" => second} =
               authed_conn(plaintext)
               |> post_json("/sync/nodes", payload)
               |> json_response(200)

      assert first == second
    end

    test "a non-positive parent cap falls back to the ordinary one-parent rule", %{
      project: project,
      plaintext: plaintext
    } do
      previous = Application.get_env(:cadence_server, :sync_max_push_parents)
      Application.put_env(:cadence_server, :sync_max_push_parents, 0)
      on_exit(fn -> restore_env(:sync_max_push_parents, previous) end)

      dag = build_merge_dag(tmp_dir())

      payload = %{
        "nodes" => [
          node_payload(project, dag.root_id, dag.root, [], dag.repo, "root"),
          node_payload(project, dag.left_id, dag.left, [dag.root_id], dag.repo, "left"),
          node_payload(project, dag.right_id, dag.right, [dag.root_id], dag.repo, "right"),
          imported(
            node_payload(
              project,
              dag.merge_id,
              dag.merge,
              [dag.left_id, dag.right_id],
              dag.repo,
              "merge"
            )
          )
        ]
      }

      assert %{
               "error" => "pushed nodes may have at most one parent",
               "failed_local_id" => failed_local_id
             } =
               authed_conn(plaintext)
               |> post_json("/sync/nodes", payload)
               |> json_response(422)

      assert failed_local_id == dag.merge_id
    end

    test "duplicate parents are refused", %{project: project, plaintext: plaintext} do
      dag = build_merge_dag(tmp_dir())

      payload = %{
        "nodes" => [
          node_payload(project, dag.root_id, dag.root, [], dag.repo, "root"),
          node_payload(project, dag.left_id, dag.left, [dag.root_id], dag.repo, "left"),
          imported(
            node_payload(
              project,
              dag.merge_id,
              dag.merge,
              [dag.left_id, dag.left_id],
              dag.repo,
              "merge"
            )
          )
        ]
      }

      assert %{"error" => "parent nodes must be unique", "failed_local_id" => id} =
               authed_conn(plaintext)
               |> post_json("/sync/nodes", payload)
               |> json_response(422)

      assert id == dag.merge_id
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

  defp subscribe_as(user_id) do
    parent = self()
    ref = make_ref()

    spawn_link(fn ->
      Phoenix.PubSub.subscribe(Cadence.Server.PubSub, "sync:user:#{user_id}")
      send(parent, {ref, :subscribed})

      receive do
        message -> send(parent, {user_id, message})
      end
    end)

    assert_receive {^ref, :subscribed}
  end

  defp seed_user(label) do
    Ash.Seed.seed!(User, %{
      email: "sync-#{label}-#{System.unique_integer([:positive])}@example.com",
      name: label
    })
  end

  defp insert_project(user, label \\ "main") do
    %Project{}
    |> Project.changeset(%{
      name: "Sync #{label}",
      slug: "sync-#{label}-#{System.unique_integer([:positive])}",
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

  defp imported(node_payload) do
    put_in(node_payload, ["metadata", "session_metadata"], %{"import" => %{"source" => "git"}})
  end

  defp build_dag(dir) do
    repo = GitStore.init(Path.join(dir, "origin"), bare: true)

    root_tree =
      build_tree(repo, Path.join(dir, "root"), %{
        "README.md" => "# Root\n",
        "src/a.txt" => "a\n"
      })

    root = GitStore.write_commit(repo, root_tree, [], @author, "root")

    child_tree = build_tree(repo, Path.join(dir, "child"), %{"README.md" => "# Child\n"})
    child = GitStore.write_commit(repo, child_tree, [root], @author, "child")

    sibling_tree =
      build_tree(repo, Path.join(dir, "sibling"), %{"README.md" => "# Sibling\n"})

    sibling = GitStore.write_commit(repo, sibling_tree, [root], @author, "sibling")

    %{
      repo: repo,
      root_id: Ecto.UUID.generate(),
      child_id: Ecto.UUID.generate(),
      sibling_id: Ecto.UUID.generate(),
      root: root,
      root_tree: root_tree,
      child: child,
      child_tree: child_tree,
      sibling: sibling,
      sibling_tree: sibling_tree
    }
  end

  defp build_merge_dag(dir) do
    repo = GitStore.init(Path.join(dir, "origin"), bare: true)

    root_tree =
      build_tree(repo, Path.join(dir, "merge-root"), %{"README.md" => "# Root\n"})

    root = GitStore.write_commit(repo, root_tree, [], @author, "root")

    left_tree = build_tree(repo, Path.join(dir, "merge-left"), %{"left.txt" => "left\n"})
    left = GitStore.write_commit(repo, left_tree, [root], @author, "left")

    right_tree = build_tree(repo, Path.join(dir, "merge-right"), %{"right.txt" => "right\n"})
    right = GitStore.write_commit(repo, right_tree, [root], @author, "right")

    third_tree = build_tree(repo, Path.join(dir, "merge-third"), %{"third.txt" => "third\n"})
    third = GitStore.write_commit(repo, third_tree, [root], @author, "third")

    merge_tree =
      build_tree(repo, Path.join(dir, "merge-result"), %{
        "left.txt" => "left\n",
        "right.txt" => "right\n"
      })

    merge = GitStore.write_commit(repo, merge_tree, [left, right], @author, "merge")

    octopus_tree =
      build_tree(repo, Path.join(dir, "merge-octopus"), %{
        "left.txt" => "left\n",
        "right.txt" => "right\n",
        "third.txt" => "third\n"
      })

    octopus = GitStore.write_commit(repo, octopus_tree, [left, right, third], @author, "octopus")

    %{
      repo: repo,
      root_id: Ecto.UUID.generate(),
      left_id: Ecto.UUID.generate(),
      right_id: Ecto.UUID.generate(),
      third_id: Ecto.UUID.generate(),
      merge_id: Ecto.UUID.generate(),
      octopus_id: Ecto.UUID.generate(),
      root: root,
      left: left,
      right: right,
      third: third,
      merge: merge,
      octopus: octopus
    }
  end

  defp build_tree(repo, dir, files) do
    Enum.each(files, fn {path, content} ->
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end)

    GitStore.build_tree(repo, dir)
  end

  defp snapshot_with(dir, label, files) do
    repo = GitStore.init(Path.join(dir, "origin"), bare: true)
    {repo, snapshot_in(repo, dir, label, files)}
  end

  defp snapshot_in(repo, dir, label, files) do
    tree = build_tree(repo, Path.join(dir, "work-#{label}"), files)
    GitStore.write_commit(repo, tree, [], @author, label)
  end

  defp open_node_incidents(project) do
    Repo.all(
      from(i in Incident,
        where: i.project_id == ^project.id and i.status == :open,
        order_by: [asc: i.id]
      )
    )
  end

  defp restore_env(key, nil), do: Application.delete_env(:cadence_server, key)
  defp restore_env(key, value), do: Application.put_env(:cadence_server, key, value)

  defp node_payload(project, local_id, commit, parents, repo, message) do
    %{
      "local_id" => local_id,
      "git_objects" => git_objects(repo, commit),
      "metadata" => %{
        "project_id" => project.id,
        "git_commit_sha" => commit,
        "parents" => parents,
        "flags" => ["in-progress"],
        "pinned" => false,
        "message" => message,
        "session_metadata" => %{},
        "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "docs_state" => "pending"
      }
    }
  end

  defp git_objects(repo, commit) do
    {:ok, objects} = GitStore.objects_from(repo, commit)

    Enum.map(objects, fn object ->
      %{
        "sha" => object.sha,
        "type" => Atom.to_string(object.type),
        "data" => Base.encode64(object.data)
      }
    end)
  end

  defp decode_objects(objects) do
    Enum.map(objects, fn object ->
      %{
        sha: object["sha"],
        type: String.to_existing_atom(object["type"]),
        data: Base.decode64!(object["data"])
      }
    end)
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "cadence_sync_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
