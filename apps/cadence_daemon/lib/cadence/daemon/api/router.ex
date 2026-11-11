defmodule Cadence.Daemon.API.Router do
  @moduledoc """
  HTTP routes for the daemon Unix socket (see spec §13 Phase 1d).
  """

  use Plug.Router

  alias Cadence.Daemon.{
    CommitQueue,
    DocDiff,
    DocQueue,
    Env,
    NodeDiff,
    Nodes,
    ProjectRegistry,
    Projects,
    Session,
    Sync,
    UnionProposal,
    Unions
  }

  alias Cadence.Shared.{DAG, UUID}

  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:match)
  plug(:dispatch)

  get "/health" do
    send_json(conn, 200, %{status: "ok"})
  end

  get "/projects" do
    send_json(conn, 200, %{projects: Projects.list_projects()})
  end

  post "/projects" do
    case Projects.register_project(conn.body_params) do
      {:ok, project} ->
        send_json(conn, 201, %{project: project_json(project)})

      {:error, :missing_work_dir} ->
        send_json(conn, 422, %{error: "work_dir is required"})

      {:error, _changeset} ->
        send_json(conn, 422, %{error: "invalid project"})
    end
  end

  get "/nodes" do
    case fetch_project(conn.query_params["project_id"]) do
      {:error, :missing} ->
        send_json(conn, 400, %{error: "project_id is required"})

      {:error, :not_found} ->
        send_json(conn, 404, %{error: "project not found"})

      {:ok, project_id} ->
        send_json(conn, 200, %{nodes: list_nodes(project_id)})
    end
  end

  get "/graph" do
    case fetch_project(conn.query_params["project_id"]) do
      {:error, :missing} ->
        send_json(conn, 400, %{error: "project_id is required"})

      {:error, :not_found} ->
        send_json(conn, 404, %{error: "project not found"})

      {:ok, project_id} ->
        send_json(conn, 200, graph_json(project_id))
    end
  end

  get "/diff" do
    project_param = conn.query_params["project_id"]
    node_id = conn.query_params["node_id"]

    if is_nil(project_param) or is_nil(node_id) do
      send_json(conn, 400, %{error: "project_id and node_id are required"})
    else
      case fetch_project(project_param) do
        {:error, :not_found} ->
          send_json(conn, 404, %{error: "project not found"})

        {:ok, project_id} ->
          case NodeDiff.build(project_id, node_id) do
            {:ok, payload} ->
              send_json(conn, 200, payload)

            {:error, :not_found} ->
              send_json(conn, 404, %{error: "node not found in project"})

            {:error, :no_location} ->
              send_json(conn, 404, %{error: "project location not found"})

            {:error, :no_commit} ->
              send_json(conn, 404, %{error: "commit not found"})
          end
      end
    end
  end

  post "/docs/sync" do
    case docs_sync(conn.body_params) do
      {:queued, node_id} ->
        send_json(conn, 202, %{status: "queued", node_id: node_id})

      {:skipped, reason} ->
        send_json(conn, 200, %{status: "skipped", reason: Atom.to_string(reason)})

      {:error, reason} ->
        docs_sync_error(conn, reason)
    end
  end

  get "/docs/diff" do
    project_param = conn.query_params["project_id"]
    node_id = conn.query_params["node_id"]

    if is_nil(project_param) do
      send_json(conn, 400, %{error: "project_id is required"})
    else
      case fetch_project(project_param) do
        {:error, :not_found} ->
          send_json(conn, 404, %{error: "project not found"})

        {:ok, project_id} ->
          case DocDiff.build(project_id, node_id) do
            {:ok, payload} ->
              send_json(conn, 200, payload)

            {:error, reason} ->
              docs_diff_error(conn, reason)
          end
      end
    end
  end

  post "/spawn" do
    case spawn_node(conn.body_params) do
      {:ok, node} ->
        send_json(conn, 201, %{node: node_json(node)})

      {:error, :no_project} ->
        send_json(conn, 404, %{error: "project not found"})

      {:error, :no_current_node} ->
        send_json(conn, 409, %{error: "no current node"})
    end
  end

  post "/switch" do
    case switch_node(conn.body_params) do
      {:ok, membership} ->
        send_json(conn, 200, %{session_pointer: membership.session_pointer})

      {:error, :no_project} ->
        send_json(conn, 404, %{error: "project not found"})

      {:error, :not_found} ->
        send_json(conn, 404, %{error: "node not found in project"})
    end
  end

  post "/union" do
    case propose_union(conn.body_params) do
      {:ok, proposal} ->
        send_json(conn, 201, union_json(proposal))

      {:error, reason} ->
        union_error(conn, reason)
    end
  end

  get "/proposals" do
    case list_proposals(conn.query_params["project_id"]) do
      {:ok, proposals} ->
        send_json(conn, 200, %{proposals: proposals})

      {:error, :missing} ->
        send_json(conn, 400, %{error: "project_id is required"})

      {:error, :not_found} ->
        send_json(conn, 404, %{error: "project not found"})
    end
  end

  match _ do
    send_json(conn, 404, %{error: "not found"})
  end

  defp spawn_node(%{"project_id" => project_id} = body) do
    case ProjectRegistry.lookup_queue(project_id) do
      nil -> {:error, :no_project}
      queue -> CommitQueue.spawn(queue, body["name"] || "spawn")
    end
  end

  defp spawn_node(_), do: {:error, :no_project}

  defp switch_node(%{"project_id" => project_id, "node_id" => node_id}) do
    if ProjectRegistry.lookup_queue(project_id) do
      Session.switch(project_id, node_id)
    else
      {:error, :no_project}
    end
  end

  defp switch_node(_), do: {:error, :no_project}

  defp docs_sync(%{"project_id" => project_id} = body) when is_binary(project_id) do
    node_id = body["node_id"]

    if is_nil(node_id) or is_binary(node_id) do
      case UUID.cast(project_id) do
        {:ok, project_id} ->
          if Projects.get_project(project_id) do
            DocQueue.sync(project_id, node_id)
          else
            {:error, :project_not_found}
          end

        :error ->
          {:error, :invalid_payload}
      end
    else
      {:error, :invalid_payload}
    end
  end

  defp docs_sync(_body), do: {:error, :invalid_payload}

  defp docs_sync_error(conn, :invalid_payload) do
    send_json(conn, 422, %{error: "invalid payload"})
  end

  defp docs_sync_error(conn, :invalid_project) do
    send_json(conn, 422, %{error: "invalid project_id"})
  end

  defp docs_sync_error(conn, :invalid_node) do
    send_json(conn, 422, %{error: "invalid node_id"})
  end

  defp docs_sync_error(conn, :project_not_found) do
    send_json(conn, 404, %{error: "project not found"})
  end

  defp docs_sync_error(conn, :not_found) do
    send_json(conn, 404, %{error: "node not found in project"})
  end

  defp docs_sync_error(conn, :no_node) do
    send_json(conn, 404, %{error: "no current node"})
  end

  defp docs_sync_error(conn, :no_location) do
    send_json(conn, 404, %{error: "project location not found"})
  end

  defp docs_sync_error(conn, :not_configured) do
    send_json(conn, 503, %{error: "doc agent is not configured"})
  end

  defp docs_sync_error(conn, :node_update_failed) do
    send_json(conn, 500, %{error: "failed to queue docs"})
  end

  defp docs_diff_error(conn, :not_found) do
    send_json(conn, 404, %{error: "node not found in project"})
  end

  defp docs_diff_error(conn, :no_location) do
    send_json(conn, 404, %{error: "project location not found"})
  end

  defp docs_diff_error(conn, :no_commit) do
    send_json(conn, 404, %{error: "commit not found"})
  end

  defp docs_diff_error(conn, :no_docs_commit) do
    send_json(conn, 409, %{error: "no docs commit for this node"})
  end

  defp docs_diff_error(conn, :no_schema) do
    send_json(conn, 409, %{error: "docs schema not found"})
  end

  defp docs_diff_error(conn, _reason) do
    send_json(conn, 500, %{error: "failed to build docs diff"})
  end

  defp propose_union(%{"project_id" => project_id, "parent_node_ids" => ids})
       when is_list(ids) do
    if length(ids) >= 2 and length(ids) <= 8 do
      case fetch_project(project_id) do
        {:ok, project_id} -> Sync.propose_union(project_id, ids)
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_parent}
    end
  end

  defp propose_union(_body), do: {:error, :invalid_payload}

  defp union_json(proposal) do
    %{
      proposal_id: proposal.proposal_id,
      proposal_token: proposal.proposal_token,
      proposal_url: present_url(proposal.proposal_url, proposal.proposal_token),
      status: proposal.status,
      kind: proposal.kind
    }
  end

  defp list_proposals(nil), do: {:error, :missing}

  defp list_proposals(project_id) do
    case fetch_project(project_id) do
      {:ok, project_id} ->
        {:ok, project_id |> Unions.list() |> Enum.map(&proposal_json/1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp proposal_json(%UnionProposal{} = proposal) do
    %{
      id: proposal.id,
      token: proposal.token,
      url: present_url(proposal.url, proposal.token),
      kind: proposal.kind,
      status: proposal.status,
      parent_node_ids: proposal.parent_node_ids,
      created_at: iso8601(proposal.created_at),
      age_seconds: age_seconds(proposal.created_at)
    }
  end

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(_value), do: nil

  defp age_seconds(%DateTime{} = created_at) do
    max(DateTime.diff(DateTime.utc_now(), created_at, :second), 0)
  end

  defp age_seconds(_created_at), do: 0

  # The server returns the public link (built from CAD_PUBLIC_URL). Fall back to
  # the daemon's API base for an older server, a pre-migration journal row, or a
  # malformed/empty value — never return an empty link.
  defp present_url(url, _token) when is_binary(url) and url != "", do: url
  defp present_url(_url, token), do: proposal_url(token)

  defp proposal_url(token) when is_binary(token) do
    case Env.server_url() do
      url when is_binary(url) and url != "" ->
        String.trim_trailing(url, "/") <> "/proposals/" <> token

      _ ->
        nil
    end
  end

  defp union_error(conn, :invalid_payload) do
    send_json(conn, 422, %{error: "project_id and parent_node_ids are required"})
  end

  defp union_error(conn, :invalid_parent) do
    send_json(conn, 422, %{error: "select between two and eight nodes"})
  end

  defp union_error(conn, :missing) do
    send_json(conn, 422, %{error: "project_id is required"})
  end

  defp union_error(conn, :not_configured) do
    send_json(conn, 503, %{error: "sync is not configured"})
  end

  defp union_error(conn, %Req.TransportError{reason: :timeout}) do
    send_json(conn, 504, %{error: "sync timed out"})
  end

  defp union_error(conn, %Req.TransportError{}) do
    send_json(conn, 503, %{error: "sync server unreachable"})
  end

  defp union_error(conn, {:http, 422, %{"error" => "invalid parent"}}) do
    send_json(conn, 422, %{error: "one or more selected nodes are not synced yet"})
  end

  defp union_error(conn, {:http, 429, _body}) do
    send_json(conn, 429, %{error: "meld rate limited; retry shortly"})
  end

  defp union_error(conn, {:http, status, body})
       when status in [401, 403, 404, 409, 422, 429, 500, 502] do
    send_json(conn, status, %{error: union_message(body)})
  end

  defp union_error(conn, reason) when reason in [:not_found, :no_location] do
    send_json(conn, 404, %{error: "project not found"})
  end

  defp union_error(conn, _reason) do
    send_json(conn, 502, %{error: "sync union failed"})
  end

  defp union_message(%{"error" => message}) when is_binary(message), do: message
  defp union_message(_body), do: "sync union failed"

  defp fetch_project(nil), do: {:error, :missing}

  defp fetch_project(project_id) do
    if Projects.get_project(project_id), do: {:ok, project_id}, else: {:error, :not_found}
  end

  defp list_nodes(project_id) do
    project_id |> Nodes.list() |> Enum.map(&node_json/1)
  end

  # Structural graph for the Neovim picker (spec §6.2, §13 Phase 2a): nodes with
  # topological depth, parent->child edges, and the resolved default/preview
  # node. Coordinate/glyph layout is the renderer's concern.
  defp graph_json(project_id) do
    nodes = Nodes.list(project_id)
    depths = DAG.depths(nodes)
    session = Session.state(project_id)

    default =
      DAG.default_node(nodes,
        session_pointer: session.session_pointer,
        user_id: session.user_id
      )

    preview = DAG.preview_node(nodes)

    %{
      project_id: project_id,
      session: session,
      default_node_id: default && default.id,
      preview_node_id: preview && preview.id,
      nodes: Enum.map(nodes, &Map.put(node_json(&1), :depth, Map.get(depths, &1.id, 0))),
      edges: DAG.edges(nodes)
    }
  end

  defp project_json(project) do
    %{
      id: project.id,
      name: project.name,
      slug: project.slug,
      owner_id: project.owner_id,
      created_at: project.created_at
    }
  end

  defp node_json(node) do
    %{
      id: node.id,
      project_id: node.project_id,
      git_commit_sha: node.git_commit_sha,
      parents: node.parents,
      flags: node.flags,
      pinned: node.pinned,
      message: node.message,
      session_metadata: node.session_metadata,
      created_by: node.created_by,
      created_at: node.created_at,
      docs_state: node.docs_state
    }
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
