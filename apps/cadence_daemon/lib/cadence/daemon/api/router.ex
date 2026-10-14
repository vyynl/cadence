defmodule Cadence.Daemon.API.Router do
  @moduledoc """
  HTTP routes for the daemon Unix socket (see spec §13 Phase 1d).
  """

  use Plug.Router

  import Ecto.Query

  alias Cadence.Daemon.{CommitQueue, ProjectRegistry, Projects, Repo, Session}
  alias Cadence.Shared.{DAG, Node}

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

  defp fetch_project(nil), do: {:error, :missing}

  defp fetch_project(project_id) do
    if Projects.get_project(project_id), do: {:ok, project_id}, else: {:error, :not_found}
  end

  defp list_nodes(project_id) do
    project_id |> project_nodes() |> Enum.map(&node_json/1)
  end

  defp project_nodes(project_id) do
    Node
    |> where([n], n.project_id == ^project_id)
    |> order_by([n], desc: n.created_at, desc: n.id)
    |> Repo.all()
  end

  # Structural graph for the Neovim picker (spec §6.2, §13 Phase 2a): nodes with
  # topological depth, parent->child edges, and the resolved default/preview
  # node. Coordinate/glyph layout is the renderer's concern.
  defp graph_json(project_id) do
    nodes = project_nodes(project_id)
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
