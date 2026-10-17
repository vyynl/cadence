defmodule Cadence.ServerWeb.SyncController do
  @moduledoc """
  Sync API endpoints: bearer-key diagnostics, node push, and cursor pulls.
  """

  use Cadence.ServerWeb, :controller

  alias Cadence.Server.Sync

  def me(conn, _params) do
    user = conn.assigns.current_user

    json(conn, 200, %{
      user_id: user.id,
      email: to_string(user.email),
      name: user.name
    })
  end

  def push_nodes(conn, _params) do
    case Sync.push_nodes(conn.assigns.current_user, conn.body_params) do
      {:ok, response} -> json(conn, 200, response)
      {:error, reason} -> error(conn, reason)
    end
  end

  def pull_nodes(conn, params) do
    project_id = params["project_id"]

    if is_nil(project_id) do
      json(conn, 400, %{error: "project_id is required"})
    else
      case Sync.pull_nodes(conn.assigns.current_user, project_id, params["since"]) do
        {:ok, response} -> json(conn, 200, response)
        {:error, reason} -> error(conn, reason)
      end
    end
  end

  defp error(conn, reason) do
    json(conn, status(reason), %{error: message(reason)})
  end

  defp status(:invalid_cursor), do: 400
  defp status(:not_found), do: 404
  defp status(:forbidden), do: 403
  defp status(:conflict), do: 409
  defp status(:duplicate_local_id), do: 409
  defp status(:object_store_incomplete), do: 500
  defp status(_reason), do: 422

  defp message(:not_found), do: "project not found"
  defp message(:forbidden), do: "not a project member"
  defp message(:conflict), do: "node id conflict"
  defp message(:duplicate_local_id), do: "duplicate local_id in batch"
  defp message(:invalid_payload), do: "invalid sync payload"
  defp message(:invalid_uuid), do: "invalid uuid"
  defp message(:invalid_cursor), do: "invalid cursor"
  defp message(:mixed_projects), do: "all nodes in a batch must share one project"
  defp message(:multiple_parents), do: "pushed nodes may have at most one parent"

  defp message(:unknown_parent),
    do: "parent node does not exist (parents-first ordering required)"

  defp message(:missing_commit), do: "commit object missing from push"
  defp message({:invalid_objects, _reason}), do: "invalid git objects"
  defp message(:object_store_incomplete), do: "server object store is incomplete"
  defp message(:invalid_node), do: "invalid node metadata"
  defp message(:invalid_flag), do: "invalid flag"
  defp message(:invalid_docs_state), do: "invalid docs_state"
  defp message(:invalid_created_at), do: "invalid created_at"
  defp message(:invalid_message), do: "invalid message"
  defp message(:invalid_session_metadata), do: "invalid session_metadata"
  defp message(:invalid_parent), do: "invalid parent"
  defp message(:invalid_commit_sha), do: "invalid git_commit_sha"
  defp message(_reason), do: "sync failed"
end
