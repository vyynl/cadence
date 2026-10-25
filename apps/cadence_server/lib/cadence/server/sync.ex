defmodule Cadence.Server.Sync do
  @moduledoc """
  Server-side sync context: object import, node push, and cursor-based pull.

  Nodes keep the daemon's UUID as their cloud ID (identity mapping), which
  makes retries idempotent. Pushes are fail-fast and must be parents-first;
  melds remain server-side-only (spec §10.4, phase-2b plan §8).
  """

  import Ecto.Query

  alias Cadence.Server.{ProjectGit, Repo}
  alias Cadence.Shared.{GitStore, Membership, Node, Project, UUID}
  alias Cadence.Shared.Sync.NodeCodec

  @writable_roles [:owner, :trusted]
  @max_parents 1

  @type user :: Ash.Resource.record()

  @doc """
  Push a batch of local nodes for one project.

  Returns the identity mappings on success. The caller must be an
  `:owner`/`:trusted` member; all nodes must belong to the same project.
  """
  @spec push_nodes(user(), map()) :: {:ok, %{mappings: [map()]}} | {:error, term()}
  def push_nodes(user, %{"nodes" => nodes}) when is_list(nodes) and nodes != [] do
    with {:ok, project_id} <- single_project(nodes),
         {:ok, role} <- authorize(user, project_id),
         {:ok, parsed} <- parse_nodes(nodes, project_id, user),
         {:ok, mappings} <-
           Repo.transaction(fn -> insert_nodes(parsed, project_id, role) end) do
      broadcast(project_id, Enum.map(mappings, & &1.cloud_id))
      broadcast_sync_available(user.id, project_id)
      {:ok, %{mappings: mappings}}
    end
  end

  def push_nodes(_user, _params), do: {:error, :invalid_payload}

  @doc """
  Pull nodes for a project after an integer cursor.

  Returns `%{nodes: [...], cursor: next_cursor, preferences: ...}`. Nodes include
  their reachable Git objects, base64-encoded for transport. Preferences are
  the caller's current per-project session state.
  """
  @spec pull_nodes(user(), String.t(), String.t() | nil) ::
          {:ok, %{nodes: [map()], cursor: String.t(), preferences: map()}}
          | {:error, term()}
  def pull_nodes(user, project_id, cursor) do
    with {:ok, project_id} <- uuid(project_id),
         {:ok, membership} <- authorize_membership(user, project_id),
         {:ok, since} <- parse_cursor(cursor) do
      limit = Application.get_env(:cadence_server, :sync_pull_limit, 100)
      store = ProjectGit.open(project_id)

      rows =
        Node
        |> where([n], n.project_id == ^project_id and fragment("seq") > ^since)
        |> order_by([n], asc: fragment("seq"))
        |> limit(^limit)
        |> select([n], %{node: n, seq: fragment("seq")})
        |> Repo.all()

      with {:ok, nodes} <- encode_nodes(rows, store) do
        next_cursor =
          case rows do
            [] -> Integer.to_string(since)
            _ -> rows |> Enum.map(& &1.seq) |> Enum.max() |> Integer.to_string()
          end

        {:ok,
         %{
           nodes: nodes,
           cursor: next_cursor,
           preferences: preferences_json(membership)
         }}
      end
    end
  end

  @doc """
  Pushes the caller's versioned per-project preferences.

  A write wins only when `updated_at` is strictly newer than the stored
  `preferences_updated_at`. Stale writes return the current preferences without
  changing the row. Accepted writes broadcast on the project topic.
  """
  @spec push_preferences(user(), map()) ::
          {:ok, %{preferences: map()}} | {:error, term()}
  def push_preferences(user, %{"project_id" => project_id} = params) do
    with {:ok, project_id} <- uuid(project_id),
         {:ok, membership} <- authorize_membership(user, project_id),
         {:ok, active_heads} <- uuid_list(params["active_heads"] || []),
         {:ok, session_pointer} <- optional_uuid(params["session_pointer"]),
         {:ok, updated_at} <- parse_updated_at(params["updated_at"]) do
      if newer_preferences?(updated_at, membership.preferences_updated_at) do
        update_preferences(membership, project_id, user, %{
          active_heads: active_heads,
          session_pointer: session_pointer,
          preferences_updated_at: updated_at,
          last_seen_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
      else
        {:ok, %{preferences: preferences_json(membership)}}
      end
    end
  end

  def push_preferences(_user, _params), do: {:error, :invalid_payload}

  ## Push

  defp single_project([%{"metadata" => %{"project_id" => project_id}} | _] = nodes)
       when is_binary(project_id) do
    with {:ok, project_id} <- uuid(project_id),
         true <-
           Enum.all?(nodes, fn node ->
             matched_project?(node_project_id(node), project_id)
           end) do
      {:ok, project_id}
    else
      false -> {:error, :mixed_projects}
      {:error, reason} -> {:error, reason}
    end
  end

  defp single_project(_nodes), do: {:error, :invalid_payload}

  defp authorize(user, project_id) do
    with {:ok, membership} <- authorize_membership(user, project_id) do
      {:ok, membership.role}
    end
  end

  defp authorize_membership(user, project_id) do
    case Repo.get(Project, project_id) do
      nil ->
        {:error, :not_found}

      _project ->
        case Repo.get_by(Membership, user_id: user.id, project_id: project_id) do
          %{role: role} = membership when role in @writable_roles -> {:ok, membership}
          _ -> {:error, :forbidden}
        end
    end
  end

  defp parse_nodes(nodes, project_id, user) do
    nodes
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn node, {:ok, acc, seen} ->
      case parse_node(node, project_id, user) do
        {:ok, parsed} ->
          if MapSet.member?(seen, parsed.local_id) do
            {:halt, {:error, :duplicate_local_id}}
          else
            {:cont, {:ok, [parsed | acc], MapSet.put(seen, parsed.local_id)}}
          end

        {:error, reason} ->
          {:halt, {:error, wrap_node_error(node, reason)}}
      end
    end)
    |> case do
      {:ok, parsed, _seen} -> {:ok, Enum.reverse(parsed)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp wrap_node_error(node, reason) do
    case node_local_id(node) do
      {:ok, local_id} -> {:node_error, local_id, reason}
      :error -> reason
    end
  end

  defp node_local_id(%{"local_id" => local_id}) do
    case uuid(local_id) do
      {:ok, local_id} -> {:ok, local_id}
      {:error, _reason} -> :error
    end
  end

  defp node_local_id(_node), do: :error

  defp parse_node(%{"local_id" => local_id, "metadata" => metadata} = node, project_id, user)
       when is_map(metadata) do
    with {:ok, local_id} <- uuid(local_id),
         true <- matched_project?(metadata["project_id"], project_id),
         {:ok, objects} <- NodeCodec.decode_objects(Map.get(node, "git_objects", [])),
         {:ok, attrs} <- node_attrs(metadata, local_id, project_id, user) do
      {:ok, %{local_id: local_id, objects: objects, attrs: attrs}}
    else
      false -> {:error, :mixed_projects}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_node(_node, _project_id, _user), do: {:error, :invalid_payload}

  defp node_attrs(metadata, local_id, project_id, user) do
    with {:ok, sha} <- commit_sha(metadata["git_commit_sha"]),
         {:ok, parents} <- parents(metadata["parents"] || []),
         :ok <- max_parents(parents),
         {:ok, flags} <- flags(metadata["flags"] || []),
         {:ok, docs_state} <- docs_state(metadata["docs_state"]),
         {:ok, session_metadata} <- session_metadata(metadata["session_metadata"]),
         {:ok, created_at} <- created_at(metadata["created_at"]),
         {:ok, message} <- message(metadata["message"]) do
      {:ok,
       %{
         id: local_id,
         project_id: project_id,
         git_commit_sha: sha,
         parents: parents,
         flags: flags,
         pinned: metadata["pinned"] == true,
         message: message,
         session_metadata: session_metadata,
         created_by: user.id,
         created_at: created_at,
         docs_state: docs_state
       }}
    end
  end

  defp commit_sha(sha) when is_binary(sha) do
    if Regex.match?(~r/^[0-9a-f]{40}$/, sha), do: {:ok, sha}, else: {:error, :invalid_commit_sha}
  end

  defp commit_sha(_sha), do: {:error, :invalid_commit_sha}

  defp parents(parents) when is_list(parents) do
    Enum.reduce_while(parents, {:ok, []}, fn parent, {:ok, acc} ->
      case uuid(parent) do
        {:ok, parent} -> {:cont, {:ok, [parent | acc]}}
        {:error, _} -> {:halt, {:error, :invalid_parent}}
      end
    end)
    |> case do
      {:ok, parents} -> {:ok, Enum.reverse(parents)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parents(_parents), do: {:error, :invalid_parent}

  defp max_parents(parents) do
    if length(parents) <= @max_parents, do: :ok, else: {:error, :multiple_parents}
  end

  defp flags(flags) when is_list(flags) do
    case NodeCodec.decode_flags(flags) do
      {:ok, flags} -> {:ok, flags}
      {:error, _reason} -> {:error, :invalid_flag}
    end
  end

  defp flags(_flags), do: {:error, :invalid_flag}

  defp docs_state(state) do
    case NodeCodec.decode_docs_state(state) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp session_metadata(metadata) when is_map(metadata), do: {:ok, metadata}
  defp session_metadata(nil), do: {:ok, %{}}
  defp session_metadata(_metadata), do: {:error, :invalid_session_metadata}

  defp created_at(nil), do: {:ok, DateTime.utc_now()}

  defp created_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.shift_zone!(datetime, "Etc/UTC")}
      _ -> {:error, :invalid_created_at}
    end
  end

  defp created_at(_value), do: {:error, :invalid_created_at}

  defp message(nil), do: {:ok, nil}
  defp message(message) when is_binary(message), do: {:ok, message}
  defp message(_message), do: {:error, :invalid_message}

  defp insert_nodes(parsed, project_id, role) do
    store = ProjectGit.init(project_id)

    result =
      Enum.reduce_while(parsed, {:ok, []}, fn node, {:ok, mappings} ->
        case insert_node(store, node, project_id, role) do
          {:ok, mapping} -> {:cont, {:ok, [mapping | mappings]}}
          {:error, reason} -> {:halt, {:error, {:node_error, node.local_id, reason}}}
        end
      end)

    case result do
      {:ok, mappings} -> Enum.reverse(mappings)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp insert_node(store, node, project_id, role) do
    case Repo.get(Node, node.local_id) do
      nil ->
        with :ok <- import_objects(store, node.objects),
             :ok <- ensure_complete(store, node.attrs.git_commit_sha),
             :ok <- check_parents(node.attrs.parents, project_id),
             {:ok, _node} <- insert_node_row(node.attrs, role) do
          {:ok, %{local_id: node.local_id, cloud_id: node.local_id}}
        end

      %Node{project_id: ^project_id} = existing ->
        if existing.git_commit_sha == node.attrs.git_commit_sha and
             existing.parents == node.attrs.parents do
          {:ok, %{local_id: node.local_id, cloud_id: node.local_id}}
        else
          {:error, :conflict}
        end

      _other ->
        {:error, :conflict}
    end
  end

  defp import_objects(store, objects) do
    case GitStore.import_objects(store, objects) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_objects, reason}}
    end
  end

  defp ensure_complete(store, commit_sha) do
    case GitStore.objects_from(store, commit_sha) do
      {:ok, _objects} -> :ok
      {:error, :missing_object} -> {:error, :missing_commit}
      {:error, :not_a_commit} -> {:error, :missing_commit}
    end
  end

  defp check_parents([], _project_id), do: :ok

  defp check_parents([parent], project_id) do
    case Repo.get_by(Node, id: parent, project_id: project_id) do
      nil -> {:error, :unknown_parent}
      _parent -> :ok
    end
  end

  defp insert_node_row(attrs, role) do
    attrs = Map.put(attrs, :pinned, attrs.pinned and role == :owner)

    try do
      case attrs |> Node.changeset() |> Repo.insert() do
        {:ok, node} -> {:ok, node}
        {:error, _changeset} -> {:error, :invalid_node}
      end
    rescue
      Ecto.ConstraintError -> {:error, :conflict}
    end
  end

  ## Pull

  defp parse_cursor(nil), do: {:ok, 0}
  defp parse_cursor(""), do: {:ok, 0}

  defp parse_cursor(cursor) when is_binary(cursor) do
    case Integer.parse(cursor) do
      {value, ""} when value >= 0 -> {:ok, value}
      _ -> {:error, :invalid_cursor}
    end
  end

  defp parse_cursor(_cursor), do: {:error, :invalid_cursor}

  defp encode_nodes(rows, store) do
    Enum.reduce_while(rows, {:ok, []}, fn %{node: node}, {:ok, acc} ->
      case GitStore.objects_from(store, node.git_commit_sha) do
        {:ok, objects} ->
          {:cont, {:ok, [NodeCodec.encode_node(node, objects) | acc]}}

        {:error, _reason} ->
          {:halt, {:error, :object_store_incomplete}}
      end
    end)
    |> case do
      {:ok, nodes} -> {:ok, Enum.reverse(nodes)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_preferences(membership, project_id, user, attrs) do
    case membership |> Membership.changeset(attrs) |> Repo.update() do
      {:ok, membership} ->
        broadcast_preferences(project_id, user.id)
        broadcast_sync_available(user.id, project_id)
        {:ok, %{preferences: preferences_json(membership)}}

      {:error, _changeset} ->
        {:error, :invalid_preferences}
    end
  end

  defp preferences_json(membership) do
    %{
      active_heads: membership.active_heads || [],
      session_pointer: membership.session_pointer,
      updated_at: NodeCodec.encode_datetime(membership.preferences_updated_at)
    }
  end

  defp newer_preferences?(_incoming, nil), do: true

  defp newer_preferences?(incoming, stored) do
    DateTime.compare(incoming, stored) == :gt
  end

  defp uuid_list(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case uuid(value) do
        {:ok, uuid} -> {:cont, {:ok, [uuid | acc]}}
        {:error, _reason} -> {:halt, {:error, :invalid_active_heads}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp uuid_list(_values), do: {:error, :invalid_active_heads}

  defp optional_uuid(nil), do: {:ok, nil}
  defp optional_uuid(value), do: uuid(value)

  defp parse_updated_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.shift_zone!(datetime, "Etc/UTC")}
      _ -> {:error, :invalid_updated_at}
    end
  end

  defp parse_updated_at(_value), do: {:error, :invalid_updated_at}

  defp broadcast_sync_available(user_id, project_id) do
    Phoenix.PubSub.broadcast(
      Cadence.Server.PubSub,
      "sync:user:#{user_id}",
      {:sync_available, project_id}
    )
  end

  defp broadcast_preferences(project_id, user_id) do
    Phoenix.PubSub.broadcast(
      Cadence.Server.PubSub,
      "project:#{project_id}",
      {:preferences_updated, project_id, user_id}
    )
  end

  ## Shared

  defp uuid(value) do
    case UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_uuid}
    end
  end

  defp matched_project?(value, project_id) when is_binary(value) do
    case uuid(value) do
      {:ok, ^project_id} -> true
      _ -> false
    end
  end

  defp matched_project?(_value, _project_id), do: false

  defp node_project_id(%{"metadata" => %{"project_id" => project_id}}), do: project_id
  defp node_project_id(_node), do: nil

  defp broadcast(project_id, node_ids) do
    Phoenix.PubSub.broadcast(
      Cadence.Server.PubSub,
      "project:#{project_id}",
      {:nodes_pushed, project_id, node_ids}
    )
  end
end
