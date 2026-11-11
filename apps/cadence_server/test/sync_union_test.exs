defmodule Cadence.ServerWeb.SyncUnionTest do
  use Cadence.ServerWeb.ConnCase, async: false

  import Cadence.ServerFixtures
  import Ecto.Query
  import Phoenix.ConnTest
  import Plug.Conn

  alias Cadence.Server.{Accounts, Incident, ProjectGit, Repo, TestMeldLLM}
  alias Cadence.Server.Accounts.User
  alias Cadence.Shared.Node

  setup do
    owner = seed_user("union-owner")
    project = project(owner.id, %{name: "Union", slug: "union"})
    membership(project, owner.id, :owner)
    {:ok, api_key} = Accounts.create_api_key(owner, "union-test")

    previous_llm = Application.get_env(:cadence_server, :meld_llm)
    Application.put_env(:cadence_server, :meld_llm, TestMeldLLM)
    TestMeldLLM.setup()

    on_exit(fn ->
      File.rm_rf!(ProjectGit.path(project.id))

      if previous_llm do
        Application.put_env(:cadence_server, :meld_llm, previous_llm)
      else
        Application.delete_env(:cadence_server, :meld_llm)
      end

      TestMeldLLM.reset()
    end)

    %{
      user: owner,
      project: project,
      plaintext: api_key.__metadata__.plaintext_api_key
    }
  end

  test "creates a pending proposal without creating a node or calling the model", %{
    conn: conn,
    project: project,
    plaintext: plaintext
  } do
    parent_a = node_with_snapshot(project, %{"a.txt" => "a"}, %{message: "a"})
    parent_b = node_with_snapshot(project, %{"b.txt" => "b"}, %{message: "b"})
    before_nodes = count_nodes(project)

    response =
      conn
      |> authed(plaintext)
      |> post_json("/sync/union", %{
        "project_id" => project.id,
        "parent_node_ids" => [parent_a.id, parent_b.id]
      })

    assert body = json_response(response, 201)
    assert body["status"] == "pending"
    assert body["kind"] == "meld"
    assert is_binary(body["proposal_id"])
    assert is_binary(body["proposal_token"])

    assert body["proposal_url"] ==
             Cadence.ServerWeb.Metadata.canonical("/proposals/#{body["proposal_token"]}")

    assert TestMeldLLM.calls() == 0

    proposal = Repo.get!(Cadence.Server.Proposal, body["proposal_id"])
    assert proposal.status == :pending
    assert proposal.kind == :meld
    assert proposal.parent_ids == [parent_a.id, parent_b.id]
    assert proposal.meld_commit_sha =~ ~r/^[0-9a-f]{40}$/
    assert proposal.result_tree_sha =~ ~r/^[0-9a-f]{40}$/
    assert count_nodes(project) == before_nodes
    assert Repo.all(from(n in Node, where: n.git_commit_sha == ^proposal.meld_commit_sha)) == []
  end

  test "a duplicate union returns the existing pending proposal", %{
    conn: conn,
    project: project,
    plaintext: plaintext
  } do
    parent_a = node_with_snapshot(project, %{"a.txt" => "a"})
    parent_b = node_with_snapshot(project, %{"b.txt" => "b"})

    payload = %{"project_id" => project.id, "parent_node_ids" => [parent_a.id, parent_b.id]}

    first = conn |> authed(plaintext) |> post_json("/sync/union", payload) |> json_response(201)
    second = conn |> authed(plaintext) |> post_json("/sync/union", payload) |> json_response(201)

    assert first["proposal_id"] == second["proposal_id"]
    assert first["proposal_token"] == second["proposal_token"]

    assert Repo.aggregate(
             from(p in Cadence.Server.Proposal, where: p.project_id == ^project.id),
             :count
           ) == 1
  end

  test "trusted members may propose; viewers may not", %{
    conn: conn,
    project: project,
    plaintext: plaintext
  } do
    parent_a = node_with_snapshot(project, %{"a.txt" => "a"})
    parent_b = node_with_snapshot(project, %{"b.txt" => "b"})

    viewer = seed_user("union-viewer")
    membership(project, viewer.id, :viewer)
    {:ok, viewer_key} = Accounts.create_api_key(viewer, "union-viewer")

    trusted = seed_user("union-trusted")
    membership(project, trusted.id, :trusted)
    {:ok, trusted_key} = Accounts.create_api_key(trusted, "union-trusted")

    payload = %{"project_id" => project.id, "parent_node_ids" => [parent_a.id, parent_b.id]}

    denied =
      conn
      |> authed(viewer_key.__metadata__.plaintext_api_key)
      |> post_json("/sync/union", payload)

    assert json_response(denied, 403) == %{"error" => "insufficient project role"}

    assert conn
           |> authed(trusted_key.__metadata__.plaintext_api_key)
           |> post_json("/sync/union", payload)
           |> json_response(201)

    # The owner key is still valid too.
    assert conn |> authed(plaintext) |> post_json("/sync/union", payload) |> json_response(201)
  end

  test "anonymous requests are rejected", %{conn: conn, project: project} do
    response =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/sync/union",
        Jason.encode!(%{"project_id" => project.id, "parent_node_ids" => []})
      )

    assert response.status == 401
  end

  test "unknown projects are 404 and invalid payloads are 422", %{
    conn: conn,
    project: project,
    plaintext: plaintext
  } do
    parent = node_with_snapshot(project, %{"a.txt" => "a"})

    assert conn
           |> authed(plaintext)
           |> post_json("/sync/union", %{
             "project_id" => Ecto.UUID.generate(),
             "parent_node_ids" => [parent.id, parent.id]
           })
           |> json_response(404)

    assert conn
           |> authed(plaintext)
           |> post_json("/sync/union", %{"project_id" => "bad-id", "parent_node_ids" => []})
           |> json_response(422)

    assert conn
           |> authed(plaintext)
           |> post_json("/sync/union", %{
             "project_id" => project.id,
             "parent_node_ids" => "not-a-list"
           })
           |> json_response(422)
  end

  test "invalid parents and too many parents are 422", %{
    conn: conn,
    project: project,
    plaintext: plaintext
  } do
    parent = node_with_snapshot(project, %{"a.txt" => "a"})

    assert conn
           |> authed(plaintext)
           |> post_json("/sync/union", %{
             "project_id" => project.id,
             "parent_node_ids" => [parent.id]
           })
           |> json_response(422)

    assert conn
           |> authed(plaintext)
           |> post_json("/sync/union", %{
             "project_id" => project.id,
             "parent_node_ids" => [parent.id, Ecto.UUID.generate()]
           })
           |> json_response(422)

    nine =
      Enum.map(1..9, fn index ->
        node_with_snapshot(project, %{"f#{index}.txt" => "#{index}"})
      end)

    assert conn
           |> authed(plaintext)
           |> post_json("/sync/union", %{
             "project_id" => project.id,
             "parent_node_ids" => Enum.map(nine, & &1.id)
           })
           |> json_response(422)
  end

  test "a model failure is 502 and opens an incident", %{
    conn: conn,
    project: project,
    plaintext: plaintext
  } do
    parent_a = node_with_snapshot(project, %{"conflict.txt" => "one"}, %{message: "a"})
    parent_b = node_with_snapshot(project, %{"conflict.txt" => "two"}, %{message: "b"})

    # Provider errors are wrapped as `{:llm, _}` and retried once
    # (`meld_retry_attempts: 1` in test config), so both attempts fail.
    TestMeldLLM.script([{:error, :timeout}, {:error, :timeout}])

    response =
      conn
      |> authed(plaintext)
      |> post_json("/sync/union", %{
        "project_id" => project.id,
        "parent_node_ids" => [parent_a.id, parent_b.id]
      })

    assert json_response(response, 502) == %{"error" => "meld failed"}
    assert TestMeldLLM.calls() == 2

    assert [incident] =
             Repo.all(
               from(i in Incident,
                 where: i.project_id == ^project.id and i.kind == :meld_failed
               )
             )

    assert incident.severity == :high
  end

  test "a rate-limited meld is 429 with Retry-After", %{
    conn: conn,
    project: project,
    plaintext: plaintext
  } do
    previous = Application.get_env(:cadence_server, :meld_rate_limit)
    Application.put_env(:cadence_server, :meld_rate_limit, 0)
    on_exit(fn -> Application.put_env(:cadence_server, :meld_rate_limit, previous) end)

    parent_a = node_with_snapshot(project, %{"conflict.txt" => "one"}, %{message: "a"})
    parent_b = node_with_snapshot(project, %{"conflict.txt" => "two"}, %{message: "b"})

    response =
      conn
      |> authed(plaintext)
      |> post_json("/sync/union", %{
        "project_id" => project.id,
        "parent_node_ids" => [parent_a.id, parent_b.id]
      })

    assert json_response(response, 429) == %{"error" => "meld rate limited"}
    assert [retry_after] = get_resp_header(response, "retry-after")
    assert String.to_integer(retry_after) >= 1
    assert TestMeldLLM.calls() == 0
    assert Repo.aggregate(from(p in Cadence.Server.Proposal), :count) == 0
  end

  defp count_nodes(project) do
    Repo.aggregate(from(n in Node, where: n.project_id == ^project.id), :count)
  end

  defp authed(conn, plaintext) do
    put_req_header(conn, "authorization", "Bearer #{plaintext}")
  end

  defp post_json(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp seed_user(label) do
    Ash.Seed.seed!(User, %{
      email: "union-#{label}-#{System.unique_integer([:positive])}@example.com",
      name: label
    })
  end
end
