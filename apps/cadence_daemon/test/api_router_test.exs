defmodule Cadence.Daemon.API.RouterTest do
  use ExUnit.Case, async: false

  alias Cadence.Daemon.API.Router
  alias Cadence.Daemon.{DocQueue, ProjectLocation, Repo, SyncLedger, SyncPending, Unions}
  alias Cadence.Shared.{GitStore, Membership, Node, Project}

  @schema """
  index_file: README.md
  docs_dir: docs
  sections:
    - name: Overview
      required: true
      generated_from: "lib/**/*.ex"
  """

  defp call(conn), do: Router.call(conn, [])

  test "GET /health" do
    conn = Plug.Test.conn(:get, "/health") |> call()
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["status"] == "ok"
  end

  test "GET /projects returns a list" do
    conn = Plug.Test.conn(:get, "/projects") |> call()
    assert conn.status == 200
    assert is_list(Jason.decode!(conn.resp_body)["projects"])
  end

  test "POST /projects with an invalid slug returns 422" do
    conn =
      Plug.Test.conn(
        :post,
        "/projects",
        Jason.encode!(%{
          "name" => "x",
          "slug" => "NOT_VALID",
          "work_dir" => "/tmp/x"
        })
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> call()

    assert conn.status == 422
  end

  test "POST /projects missing work_dir returns 422" do
    conn =
      Plug.Test.conn(:post, "/projects", Jason.encode!(%{"name" => "x", "slug" => "x-1"}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> call()

    assert conn.status == 422
  end

  test "GET /nodes requires project_id" do
    conn = Plug.Test.conn(:get, "/nodes") |> call()
    assert conn.status == 400
  end

  test "GET /nodes orders deterministically when timestamps tie" do
    owner_id = Ecto.UUID.generate()

    {:ok, project} =
      %{name: "n", slug: "nodes-#{System.unique_integer([:positive])}", owner_id: owner_id}
      |> Project.changeset()
      |> Repo.insert()

    created_at = ~U[2026-10-14 12:00:00.000000Z]
    [high_id, low_id] = Enum.sort([Ecto.UUID.generate(), Ecto.UUID.generate()], :desc)

    Enum.each([low_id, high_id], fn id ->
      %{
        id: id,
        project_id: project.id,
        git_commit_sha: String.duplicate("c", 40),
        flags: [:"in-progress"],
        message: "m",
        created_by: owner_id,
        created_at: created_at,
        docs_state: :pending
      }
      |> Node.changeset()
      |> Repo.insert!()
    end)

    conn = Plug.Test.conn(:get, "/nodes?project_id=#{project.id}") |> call()
    assert conn.status == 200

    assert Enum.map(Jason.decode!(conn.resp_body)["nodes"], & &1["id"]) == [high_id, low_id]
  end

  test "POST /union validates its payload and resolves the local project" do
    assert post_json("/union", %{}).status == 422
    assert post_json("/union", %{"project_id" => nil, "parent_node_ids" => []}).status == 422

    nine = Enum.map(1..9, fn _ -> Ecto.UUID.generate() end)

    assert post_json("/union", %{
             "project_id" => Ecto.UUID.generate(),
             "parent_node_ids" => nine
           }).status == 422

    assert post_json("/union", %{
             "project_id" => Ecto.UUID.generate(),
             "parent_node_ids" => [Ecto.UUID.generate()]
           }).status == 422

    assert post_json("/union", %{
             "project_id" => Ecto.UUID.generate(),
             "parent_node_ids" => [Ecto.UUID.generate(), Ecto.UUID.generate()]
           }).status == 404
  end

  test "POST /union returns 503 when sync is not configured" do
    project = insert_local_project()

    conn =
      post_json("/union", %{
        "project_id" => project.id,
        "parent_node_ids" => [Ecto.UUID.generate(), Ecto.UUID.generate()]
      })

    assert conn.status == 503
    assert Jason.decode!(conn.resp_body)["error"] == "sync is not configured"
  end

  test "POST /union returns the proposal token and URL" do
    project = insert_local_project()
    configure_sync!(project)
    Req.Test.verify_on_exit!()

    proposal_id = Ecto.UUID.generate()
    parent_ids = [Ecto.UUID.generate(), Ecto.UUID.generate()]

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/sync/union"
      assert conn.body_params["project_id"] == project.id
      assert conn.body_params["parent_node_ids"] == parent_ids

      Req.Test.json(conn, %{
        proposal_id: proposal_id,
        proposal_token: "tok",
        proposal_url: "https://public.example/proposals/tok",
        status: "pending",
        kind: "meld"
      })
    end)

    conn =
      post_json("/union", %{"project_id" => project.id, "parent_node_ids" => parent_ids})

    assert conn.status == 201
    body = Jason.decode!(conn.resp_body)
    assert body["proposal_id"] == proposal_id
    assert body["proposal_token"] == "tok"
    assert body["proposal_url"] == "https://public.example/proposals/tok"
    assert body["status"] == "pending"

    proposals_conn = get_conn("/proposals?project_id=#{project.id}")
    assert proposals_conn.status == 200

    assert [proposal] = Jason.decode!(proposals_conn.resp_body)["proposals"]
    assert proposal["id"] == proposal_id
    assert proposal["token"] == "tok"
    assert proposal["url"] == "https://public.example/proposals/tok"
    assert proposal["kind"] == "meld"
    assert proposal["status"] == "pending"
    assert proposal["parent_node_ids"] == parent_ids
    assert proposal["age_seconds"] >= 0
    assert is_binary(proposal["created_at"])
  end

  test "POST /union falls back to the daemon's server URL when the server omits one" do
    project = insert_local_project()
    configure_sync!(project)
    Req.Test.verify_on_exit!()

    parent_ids = [Ecto.UUID.generate(), Ecto.UUID.generate()]

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        proposal_id: Ecto.UUID.generate(),
        proposal_token: "tok-old-server",
        status: "pending",
        kind: "meld"
      })
    end)

    conn =
      post_json("/union", %{"project_id" => project.id, "parent_node_ids" => parent_ids})

    assert conn.status == 201

    assert Jason.decode!(conn.resp_body)["proposal_url"] ==
             "http://server.test/proposals/tok-old-server"

    [proposal] =
      Jason.decode!(get_conn("/proposals?project_id=#{project.id}").resp_body)["proposals"]

    assert proposal["url"] == "http://server.test/proposals/tok-old-server"
  end

  test "POST /union falls back when the server returns an empty proposal_url" do
    project = insert_local_project()
    configure_sync!(project)
    Req.Test.verify_on_exit!()

    parent_ids = [Ecto.UUID.generate(), Ecto.UUID.generate()]

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        proposal_id: Ecto.UUID.generate(),
        proposal_token: "tok-empty-url",
        proposal_url: "",
        status: "pending",
        kind: "meld"
      })
    end)

    conn =
      post_json("/union", %{"project_id" => project.id, "parent_node_ids" => parent_ids})

    assert conn.status == 201

    assert Jason.decode!(conn.resp_body)["proposal_url"] ==
             "http://server.test/proposals/tok-empty-url"
  end

  test "GET /proposals validates the project and returns an empty list" do
    assert get_conn("/proposals").status == 400
    assert get_conn("/proposals?project_id=not-a-uuid").status == 404
    assert get_conn("/proposals?project_id=#{Ecto.UUID.generate()}").status == 404

    project = insert_local_project()
    conn = get_conn("/proposals?project_id=#{project.id}")
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"proposals" => []}
  end

  test "POST /union still succeeds when the local journal cannot record" do
    project = insert_local_project()
    configure_sync!(project)
    Req.Test.verify_on_exit!()

    parent_ids = [Ecto.UUID.generate(), Ecto.UUID.generate()]

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        proposal_id: "not-a-uuid",
        proposal_token: "tok-unrecorded",
        status: "pending",
        kind: "meld"
      })
    end)

    conn =
      post_json("/union", %{"project_id" => project.id, "parent_node_ids" => parent_ids})

    assert conn.status == 201
    assert Jason.decode!(conn.resp_body)["proposal_token"] == "tok-unrecorded"

    proposals_conn = get_conn("/proposals?project_id=#{project.id}")
    assert proposals_conn.status == 200
    assert Jason.decode!(proposals_conn.resp_body)["proposals"] == []
  end

  test "GET /proposals returns a nil URL when sync is not configured" do
    project = insert_local_project()

    {:ok, _row} =
      Unions.record(
        project.id,
        %{
          proposal_id: Ecto.UUID.generate(),
          proposal_token: "tok-offline",
          status: "pending",
          kind: "meld"
        },
        []
      )

    Application.delete_env(:cadence_daemon, :server_url)

    conn = get_conn("/proposals?project_id=#{project.id}")
    assert conn.status == 200

    assert [proposal] = Jason.decode!(conn.resp_body)["proposals"]
    assert proposal["url"] == nil
    assert proposal["token"] == "tok-offline"
  end

  test "POST /union passes through server statuses and improves actionable errors" do
    project = insert_local_project()
    configure_sync!(project)
    parent_ids = [Ecto.UUID.generate(), Ecto.UUID.generate()]
    payload = %{"project_id" => project.id, "parent_node_ids" => parent_ids}

    for {status, server_body, expected} <- [
          {403, %{"error" => "insufficient project role"}, "insufficient project role"},
          {500, %{"error" => "sync failed"}, "sync failed"},
          {502, %{"error" => "meld failed"}, "meld failed"},
          {422, %{"error" => "invalid parent"}, "one or more selected nodes are not synced yet"},
          {429, %{"error" => "meld rate limited"}, "rate limited; retry shortly"}
        ] do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, Jason.encode!(server_body))
      end)

      conn = post_json("/union", payload)
      assert conn.status == status
      assert Jason.decode!(conn.resp_body)["error"] == expected
    end
  end

  test "POST /union maps transport failures to 503 and 504" do
    project = insert_local_project()
    configure_sync!(project)

    payload = %{
      "project_id" => project.id,
      "parent_node_ids" => [Ecto.UUID.generate(), Ecto.UUID.generate()]
    }

    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
    conn = post_json("/union", payload)
    assert conn.status == 503
    assert Jason.decode!(conn.resp_body)["error"] == "sync server unreachable"

    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)
    conn = post_json("/union", payload)
    assert conn.status == 504
    assert Jason.decode!(conn.resp_body)["error"] == "sync timed out"
  end

  test "POST /spawn for an unknown project returns 404" do
    conn =
      Plug.Test.conn(:post, "/spawn", Jason.encode!(%{"project_id" => Ecto.UUID.generate()}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> call()

    assert conn.status == 404
  end

  test "POST /switch for an unknown project returns 404" do
    conn =
      Plug.Test.conn(
        :post,
        "/switch",
        Jason.encode!(%{
          "project_id" => Ecto.UUID.generate(),
          "node_id" => Ecto.UUID.generate()
        })
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> call()

    assert conn.status == 404
  end

  test "POST /switch rejects a malformed node_id" do
    project = insert_project(Ecto.UUID.generate())

    conn =
      Plug.Test.conn(
        :post,
        "/switch",
        Jason.encode!(%{"project_id" => project.id, "node_id" => "not-a-uuid"})
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> call()

    assert conn.status == 404
  end

  test "GET /nodes returns 404 for an unknown project" do
    conn = Plug.Test.conn(:get, "/nodes?project_id=#{Ecto.UUID.generate()}") |> call()
    assert conn.status == 404
  end

  test "GET /nodes returns 404 for a malformed project_id" do
    conn = Plug.Test.conn(:get, "/nodes?project_id=not-a-uuid") |> call()
    assert conn.status == 404
  end

  test "GET /graph requires project_id" do
    conn = Plug.Test.conn(:get, "/graph") |> call()
    assert conn.status == 400
  end

  test "GET /graph returns 404 for an unknown project" do
    conn = Plug.Test.conn(:get, "/graph?project_id=#{Ecto.UUID.generate()}") |> call()
    assert conn.status == 404
  end

  test "GET /graph returns structural depth, edges, and session" do
    project = insert_project(Ecto.UUID.generate())
    root_id = Ecto.UUID.generate()
    child_id = Ecto.UUID.generate()

    insert_node(project.id, root_id, [], ~U[2026-10-14 10:00:00.000000Z])
    insert_node(project.id, child_id, [root_id], ~U[2026-10-14 11:00:00.000000Z])

    conn = Plug.Test.conn(:get, "/graph?project_id=#{project.id}") |> call()
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    assert body["project_id"] == project.id
    assert body["session"]["user_id"] == Application.get_env(:cadence_daemon, :local_user_id)
    assert body["session"]["session_pointer"] == nil
    assert body["edges"] == [%{"from" => root_id, "to" => child_id}]

    depths = Map.new(body["nodes"], &{&1["id"], &1["depth"]})
    assert depths[root_id] == 0
    assert depths[child_id] == 1

    # No pointer, and the local user created both nodes → newest by that user.
    assert body["default_node_id"] == child_id
    assert body["preview_node_id"] == child_id
  end

  test "GET /diff requires project_id and node_id" do
    conn = Plug.Test.conn(:get, "/diff?project_id=#{Ecto.UUID.generate()}") |> call()
    assert conn.status == 400

    conn = Plug.Test.conn(:get, "/diff") |> call()
    assert conn.status == 400
  end

  test "GET /diff returns 404 for an unknown project" do
    conn =
      Plug.Test.conn(
        :get,
        "/diff?project_id=#{Ecto.UUID.generate()}&node_id=#{Ecto.UUID.generate()}"
      )
      |> call()

    assert conn.status == 404
  end

  test "GET /diff returns 404 for a node not in the project" do
    project = insert_project(Ecto.UUID.generate())

    conn =
      Plug.Test.conn(
        :get,
        "/diff?project_id=#{project.id}&node_id=#{Ecto.UUID.generate()}"
      )
      |> call()

    assert conn.status == 404
  end

  test "GET /diff returns 404 for a malformed node_id" do
    project = insert_project(Ecto.UUID.generate())

    conn =
      Plug.Test.conn(
        :get,
        "/diff?project_id=#{project.id}&node_id=not-a-uuid"
      )
      |> call()

    assert conn.status == 404
  end

  test "POST /docs/sync validates its payload and resolves the project" do
    assert post_json("/docs/sync", %{}).status == 422
    assert post_json("/docs/sync", %{"project_id" => "not-a-uuid"}).status == 422
    assert post_json("/docs/sync", %{"project_id" => Ecto.UUID.generate()}).status == 404

    project = insert_local_project()

    assert post_json("/docs/sync", %{
             "project_id" => project.id,
             "node_id" => "not-a-uuid"
           }).status == 422

    assert post_json("/docs/sync", %{
             "project_id" => project.id,
             "node_id" => Ecto.UUID.generate()
           }).status == 404

    assert post_json("/docs/sync", %{
             "project_id" => project.id,
             "node_id" => 123
           }).status == 422

    # No explicit node and no session anchor.
    assert post_json("/docs/sync", %{"project_id" => project.id}).status == 404
  end

  test "POST /docs/sync skips disabled docs and a missing schema" do
    project = insert_local_project()
    node = insert_node_with(project.id, %{id: Ecto.UUID.generate()})
    insert_sync_pending!(node)

    Application.put_env(:cadence_daemon, :docs_enabled, false)
    on_exit(fn -> Application.delete_env(:cadence_daemon, :docs_enabled) end)

    conn = post_json("/docs/sync", %{"project_id" => project.id, "node_id" => node.id})

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"status" => "skipped", "reason" => "disabled"}

    Application.delete_env(:cadence_daemon, :docs_enabled)

    conn = post_json("/docs/sync", %{"project_id" => project.id, "node_id" => node.id})

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"status" => "skipped", "reason" => "no_schema"}
  end

  test "POST /docs/sync skips an invalid schema" do
    fixture = insert_docs_fixture()
    node = insert_node_with(fixture.project.id, %{})
    insert_sync_pending!(node)
    File.write!(Path.join(fixture.work_dir, ".caddocs.yaml"), "sections: []\n")

    conn =
      post_json("/docs/sync", %{
        "project_id" => fixture.project.id,
        "node_id" => node.id
      })

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"status" => "skipped", "reason" => "invalid_schema"}
  end

  test "POST /docs/sync queues a child job for a node whose SHA was already pushed" do
    fixture = insert_docs_fixture()
    configure_docs!()
    write_docs_schema(fixture.work_dir)

    sha = String.duplicate("d", 40)

    node =
      insert_node_with(fixture.project.id, %{
        session_metadata: %{"docs_pushed_sha" => sha}
      })

    conn = post_json("/docs/sync", %{"project_id" => fixture.project.id, "node_id" => node.id})

    assert conn.status == 202
    assert Jason.decode!(conn.resp_body)["node_id"] == node.id
  end

  test "POST /docs/sync queues a child for a pushed stamp that predates the node SHA" do
    fixture = insert_docs_fixture()
    configure_docs!()
    write_docs_schema(fixture.work_dir)

    node =
      insert_node_with(fixture.project.id, %{
        session_metadata: %{"docs_pushed_sha" => String.duplicate("a", 40)}
      })

    conn = post_json("/docs/sync", %{"project_id" => fixture.project.id, "node_id" => node.id})

    # Any pushed stamp means the SHA is immutable, so the docs must go to a
    # child node; never a dead end and never a rewrite.
    assert conn.status == 202
    assert Jason.decode!(conn.resp_body)["node_id"] == node.id
  end

  test "POST /docs/sync returns 503 when the doc agent is not configured" do
    fixture = insert_docs_fixture()
    write_docs_schema(fixture.work_dir)
    node = insert_node_with(fixture.project.id, %{})
    insert_sync_pending!(node)

    unconfigure_docs!()

    conn =
      post_json("/docs/sync", %{
        "project_id" => fixture.project.id,
        "node_id" => node.id
      })

    assert conn.status == 503
    assert Jason.decode!(conn.resp_body)["error"] == "doc agent is not configured"
  end

  test "POST /docs/sync queues and defaults to the session anchor" do
    fixture = insert_docs_fixture()
    configure_docs!()
    write_docs_schema(fixture.work_dir)

    node = insert_node_with(fixture.project.id, %{id: Ecto.UUID.generate()})
    insert_sync_pending!(node)
    point_session!(fixture.project.id, node.id)

    conn = post_json("/docs/sync", %{"project_id" => fixture.project.id})
    assert conn.status == 202

    body = Jason.decode!(conn.resp_body)
    assert body["status"] == "queued"
    assert body["node_id"] == node.id

    conn =
      post_json("/docs/sync", %{
        "project_id" => fixture.project.id,
        "node_id" => node.id
      })

    assert conn.status == 202
  end

  test "POST /docs/sync refuses a legacy node that may already be pushed" do
    fixture = insert_docs_fixture()
    configure_docs!()
    write_docs_schema(fixture.work_dir)

    node =
      insert_node_with(fixture.project.id, %{
        docs_state: :pending,
        session_metadata: %{}
      })

    conn =
      post_json("/docs/sync", %{
        "project_id" => fixture.project.id,
        "node_id" => node.id
      })

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"status" => "skipped", "reason" => "legacy"}
    assert Repo.get!(Node, node.id).git_commit_sha == node.git_commit_sha
  end

  test "POST /docs/sync allows a legacy node that is provably unpushed" do
    fixture = insert_docs_fixture()
    configure_docs!()
    write_docs_schema(fixture.work_dir)

    node =
      insert_node_with(fixture.project.id, %{
        docs_state: :pending,
        session_metadata: %{}
      })

    insert_sync_pending!(node)

    conn =
      post_json("/docs/sync", %{
        "project_id" => fixture.project.id,
        "node_id" => node.id
      })

    assert conn.status == 202
    assert Jason.decode!(conn.resp_body)["status"] == "queued"
  end

  test "POST /docs/sync skips a node whose docs are already current" do
    fixture = insert_docs_fixture()
    code_sha = String.duplicate("c", 40)
    docs_sha = String.duplicate("d", 40)

    node =
      insert_node_with(fixture.project.id, %{
        docs_state: :current,
        session_metadata: %{
          "docs" => %{
            "state" => "current",
            "code_commit_sha" => code_sha,
            "docs_commit_sha" => docs_sha
          },
          "code_commit_sha" => code_sha
        }
      })

    conn =
      post_json("/docs/sync", %{
        "project_id" => fixture.project.id,
        "node_id" => node.id
      })

    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "status" => "skipped",
             "reason" => "already_current"
           }

    refute Map.has_key?(:sys.get_state(DocQueue).entries, node.id)
  end

  test "POST /docs/sync releases a held node when docs are disabled" do
    fixture = insert_docs_fixture()
    node = insert_held_node(fixture.project.id)

    Application.put_env(:cadence_daemon, :docs_enabled, false)
    on_exit(fn -> Application.delete_env(:cadence_daemon, :docs_enabled) end)

    conn =
      post_json("/docs/sync", %{
        "project_id" => fixture.project.id,
        "node_id" => node.id
      })

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["reason"] == "disabled"

    released = Repo.get!(Node, node.id)
    assert released.docs_state == :skipped
    assert released.session_metadata["docs"]["state"] == "skipped"
    assert pushable?(fixture.project.id, node.id)
  end

  test "POST /docs/sync releases a held node when the doc agent is unconfigured" do
    fixture = insert_docs_fixture()
    write_docs_schema(fixture.work_dir)
    node = insert_held_node(fixture.project.id)
    unconfigure_docs!()

    conn =
      post_json("/docs/sync", %{
        "project_id" => fixture.project.id,
        "node_id" => node.id
      })

    assert conn.status == 503

    released = Repo.get!(Node, node.id)
    assert released.docs_state == :pending
    assert released.session_metadata["docs"]["state"] == "deferred"
    assert pushable?(fixture.project.id, node.id)
  end

  test "POST /docs/sync releases a held node when the project location is missing" do
    project = insert_project(Ecto.UUID.generate())
    node = insert_held_node(project.id)

    conn =
      post_json("/docs/sync", %{
        "project_id" => project.id,
        "node_id" => node.id
      })

    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"] == "project location not found"

    released = Repo.get!(Node, node.id)
    assert released.docs_state == :pending
    assert released.session_metadata["docs"]["state"] == "deferred"
    assert pushable?(project.id, node.id)
  end

  test "GET /docs/diff validates the project and node" do
    assert get_conn("/docs/diff").status == 400
    assert get_conn("/docs/diff?project_id=#{Ecto.UUID.generate()}").status == 404

    project = insert_local_project()

    assert get_conn("/docs/diff?project_id=#{project.id}&node_id=#{Ecto.UUID.generate()}").status ==
             404

    assert get_conn("/docs/diff?project_id=#{project.id}&node_id=not-a-uuid").status == 404
  end

  test "GET /docs/diff returns 404/409 for a missing docs state" do
    fixture = insert_docs_fixture()
    write_docs_schema(fixture.work_dir)

    code_only = insert_node_with(fixture.project.id, %{docs_state: :skipped})

    conn = get_conn("/docs/diff?project_id=#{fixture.project.id}&node_id=#{code_only.id}")
    assert conn.status == 409
    assert Jason.decode!(conn.resp_body)["error"] == "no docs commit for this node"

    missing_commit =
      insert_node_with(fixture.project.id, %{
        git_commit_sha: String.duplicate("e", 40),
        docs_state: :current
      })

    conn = get_conn("/docs/diff?project_id=#{fixture.project.id}&node_id=#{missing_commit.id}")
    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"] == "commit not found"
  end

  test "GET /docs/diff returns the doc-only diff and defaults to the session anchor" do
    fixture = insert_docs_fixture()
    write_docs_schema(fixture.work_dir)
    git = GitStore.init(fixture.git_dir, bare: true)

    {:ok, parent_tree} = GitStore.put_files(git, %{"README.md" => "# Project\n"})
    parent_sha = GitStore.write_commit(git, parent_tree, [], docs_author(), "parent")

    parent =
      insert_node_with(fixture.project.id, %{
        git_commit_sha: parent_sha,
        docs_state: :skipped
      })

    {:ok, child_tree} =
      GitStore.merge_files(git, parent_tree, %{"docs/guide.md" => "guide\n"})

    child_sha = GitStore.write_commit(git, child_tree, [parent_sha], docs_author(), "docs")

    child =
      insert_node_with(fixture.project.id, %{
        git_commit_sha: child_sha,
        parents: [parent.id],
        docs_state: :current
      })

    conn = get_conn("/docs/diff?project_id=#{fixture.project.id}&node_id=#{child.id}")
    assert conn.status == 200

    body = Jason.decode!(conn.resp_body)
    assert body["node_id"] == child.id
    assert body["code_commit_sha"] == nil
    assert body["docs_commit_sha"] == child_sha
    assert Enum.map(body["files"], & &1["path"]) == ["docs/guide.md"]

    point_session!(fixture.project.id, child.id)

    conn = get_conn("/docs/diff?project_id=#{fixture.project.id}")
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["node_id"] == child.id

    File.rm!(Path.join(fixture.work_dir, ".caddocs.yaml"))

    conn = get_conn("/docs/diff?project_id=#{fixture.project.id}&node_id=#{child.id}")
    assert conn.status == 409
    assert Jason.decode!(conn.resp_body)["error"] == "docs schema not found"
  end

  defp configure_sync!(project) do
    {:ok, _user_id} = SyncLedger.put_server_user_id(Ecto.UUID.generate())
    :ok = SyncLedger.mark_provisioned(project.id)

    Application.put_env(:cadence_daemon, :server_url, "http://server.test")
    Application.put_env(:cadence_daemon, :auth_token, "test-token")
    Application.put_env(:cadence_daemon, :sync_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.delete_env(:cadence_daemon, :server_url)
      Application.delete_env(:cadence_daemon, :auth_token)
      Application.delete_env(:cadence_daemon, :sync_req_options)
    end)
  end

  defp post_json(path, body) do
    Plug.Test.conn(:post, path, Jason.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> call()
  end

  defp insert_local_project do
    dir =
      Path.join(System.tmp_dir!(), "cadence_api_union_#{System.unique_integer([:positive])}")

    work_dir = Path.join(dir, "work")
    File.mkdir_p!(work_dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    project =
      %{
        name: "u",
        slug: "u-#{System.unique_integer([:positive])}",
        owner_id: Ecto.UUID.generate()
      }
      |> Project.changeset()
      |> Repo.insert!()

    %ProjectLocation{}
    |> ProjectLocation.changeset(%{
      project_id: project.id,
      work_dir: work_dir,
      git_dir: Path.join(dir, "git"),
      created_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    project
  end

  defp insert_project(owner_id) do
    %{name: "g", slug: "g-#{System.unique_integer([:positive])}", owner_id: owner_id}
    |> Project.changeset()
    |> Repo.insert!()
  end

  defp insert_node(project_id, id, parents, created_at) do
    %{
      id: id,
      project_id: project_id,
      git_commit_sha: String.duplicate("d", 40),
      parents: parents,
      flags: [:"in-progress"],
      message: "m",
      created_by: Application.get_env(:cadence_daemon, :local_user_id),
      created_at: created_at,
      docs_state: :pending
    }
    |> Node.changeset()
    |> Repo.insert!()
  end

  defp insert_node_with(project_id, attrs) do
    defaults = %{
      project_id: project_id,
      git_commit_sha: String.duplicate("d", 40),
      parents: [],
      flags: [:"in-progress"],
      message: "m",
      created_by: Application.get_env(:cadence_daemon, :local_user_id),
      created_at: DateTime.utc_now(),
      docs_state: :skipped
    }

    defaults
    |> Map.merge(attrs)
    |> Node.changeset()
    |> Repo.insert!()
  end

  defp insert_docs_fixture do
    project = insert_local_project()
    location = Repo.get!(ProjectLocation, project.id)
    %{project: project, work_dir: location.work_dir, git_dir: location.git_dir}
  end

  defp write_docs_schema(work_dir) do
    File.write!(Path.join(work_dir, ".caddocs.yaml"), @schema)
  end

  defp insert_held_node(project_id) do
    sha = String.duplicate("d", 40)

    node =
      insert_node_with(project_id, %{
        docs_state: :pending,
        session_metadata: %{
          "docs" => %{"state" => "pending", "code_commit_sha" => sha},
          "code_commit_sha" => sha
        }
      })

    insert_sync_pending!(node)
    node
  end

  defp insert_sync_pending!(node) do
    now = DateTime.utc_now()

    %SyncPending{}
    |> SyncPending.changeset(%{
      node_id: node.id,
      project_id: node.project_id,
      enqueued_at: now,
      next_attempt_at: now
    })
    |> Repo.insert!()
  end

  defp pushable?(project_id, node_id) do
    project_id
    |> SyncLedger.pushable(nil, 10)
    |> Enum.any?(&(&1.id == node_id))
  end

  defp unconfigure_docs! do
    Application.delete_env(:cadence_daemon, :docs_llm)
    previous = Application.get_env(:cadence_shared, Cadence.Shared.LLM)

    Application.put_env(:cadence_shared, Cadence.Shared.LLM,
      provider: "deepseek",
      model: "test",
      api_key: nil
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:cadence_shared, Cadence.Shared.LLM, previous)
      else
        Application.delete_env(:cadence_shared, Cadence.Shared.LLM)
      end
    end)
  end

  defp point_session!(project_id, node_id) do
    %Membership{}
    |> Membership.changeset(%{
      user_id: Application.get_env(:cadence_daemon, :local_user_id),
      project_id: project_id,
      role: :owner,
      active_heads: [],
      session_pointer: node_id
    })
    |> Repo.insert!()
  end

  defp configure_docs! do
    Application.put_env(:cadence_daemon, :docs_llm, Cadence.Daemon.TestDocsLLM)
    Application.put_env(:cadence_daemon, :docs_retry_attempts, 1)
    Application.put_env(:cadence_daemon, :docs_retry_backoff_ms, 1)
    Application.put_env(:cadence_daemon, :docs_rate_limit, 1_000)

    on_exit(fn ->
      drain_doc_queue()

      for key <- [
            :docs_llm,
            :docs_retry_attempts,
            :docs_retry_backoff_ms,
            :docs_rate_limit,
            :docs_enabled,
            :test_docs_llm_result
          ] do
        Application.delete_env(:cadence_daemon, key)
      end
    end)
  end

  defp drain_doc_queue do
    Cadence.Daemon.TestHelpers.await(fn -> doc_queue_idle?() end, 5_000)
  end

  defp doc_queue_idle? do
    # An unexpected shape is not evidence of idleness: only a map with an empty
    # `entries` map counts. `:exit` (busy/timeout or shutdown) keeps polling;
    # a `KeyError` from a renamed field is left to fail the test.
    match?(%{entries: entries} when entries == %{}, doc_queue_state())
  end

  defp doc_queue_state do
    try do
      :sys.get_state(DocQueue, 2_000)
    catch
      :exit, _reason -> :unknown
    end
  end

  defp docs_author, do: %{name: "cadence", email: "cadence@local"}

  defp get_conn(path), do: Plug.Test.conn(:get, path) |> call()
end
