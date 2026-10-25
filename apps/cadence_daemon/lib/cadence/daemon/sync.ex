defmodule Cadence.Daemon.Sync do
  @moduledoc """
  Daemon sync orchestration (spec §10).

  `sync/1` ensures the server user and project exist, pushes due pending nodes,
  then pulls remote nodes until the cursor stops advancing. Network calls are
  made through `Cadence.Daemon.SyncClient`; this module owns retry/backoff and
  conflict policy. It is invoked from `Cadence.Daemon.SyncWorker`, never from the
  commit path.
  """

  require Logger

  alias Cadence.Daemon.{
    Env,
    Nodes,
    NodeStore,
    ProjectLocation,
    Projects,
    Repo,
    SyncClient,
    SyncLedger
  }

  alias Cadence.Shared.{GitStore, Membership, Node, Project, UUID}
  alias Cadence.Shared.Sync.{NodeCodec, PushPreferences}

  @permanent_statuses [400, 409, 422]
  @config_statuses [401, 403, 404]
  @permanent_backoff_ms 86_400_000
  @config_backoff_ms 300_000
  @max_transient_backoff_ms 3_600_000

  @doc """
  Runs a best-effort sync cycle for one project.

  Returns `:ok` when all due work pushed and the pull cursor is caught up, or
  `{:error, reason}`. Pending nodes remain queued on failure.
  """
  @spec sync(Ecto.UUID.t()) :: :ok | {:error, term()}
  def sync(project_id) do
    with {:ok, project_id} <- UUID.cast(project_id),
         :ok <- ensure_server_user(),
         :ok <- ensure_project(project_id),
         :ok <- push_pending(project_id) do
      preference_result = push_preferences(project_id)

      case pull(project_id) do
        :ok -> preference_result
        {:error, _reason} = error -> error
      end
    else
      :error -> {:error, :invalid_uuid}
      {:error, _reason} = error -> error
    end
  end

  @doc "Resolves and caches the authenticated server user ID."
  @spec ensure_server_user() :: :ok | {:error, term()}
  def ensure_server_user do
    if SyncLedger.server_user_id() do
      :ok
    else
      with {:ok, user_id} <- SyncClient.me() do
        case SyncLedger.put_server_user_id(user_id) do
          {:ok, _user_id} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  @doc "Ensures the local project exists on the server (idempotent)."
  @spec ensure_project(Ecto.UUID.t()) :: :ok | {:error, term()}
  def ensure_project(project_id) do
    with {:ok, project_id} <- UUID.cast(project_id) do
      case Projects.get_project(project_id) do
        nil ->
          {:error, :not_found}

        %Project{} = project ->
          case Repo.get(ProjectLocation, project_id) do
            nil ->
              {:error, :no_location}

            %ProjectLocation{} ->
              provision_if_needed(project)
          end
      end
    else
      :error -> {:error, :invalid_uuid}
    end
  end

  @doc "Pushes all currently due pending nodes for a project."
  @spec push_pending(Ecto.UUID.t()) :: :ok | {:error, term()}
  def push_pending(project_id) do
    with {:ok, project_id} <- UUID.cast(project_id) do
      do_push_pending(project_id)
    else
      :error -> {:error, :invalid_uuid}
    end
  end

  @doc """
  Pushes the local user's preferences when they are newer than the last
  accepted version.

  A newer server value returned by the push is applied locally; a stale server
  value is ignored. The local version is only marked pushed after a successful
  exchange.
  """
  @spec push_preferences(Ecto.UUID.t()) :: :ok | {:error, term()}
  def push_preferences(project_id) do
    with {:ok, project_id} <- UUID.cast(project_id) do
      do_push_preferences(project_id)
    else
      :error -> {:error, :invalid_uuid}
    end
  end

  @doc """
  Applies remote preferences when they are strictly newer than the local
  version.

  `active_heads` is filtered to nodes present locally; a `session_pointer` is
  applied only when its node exists locally. Applied values are marked so they
  are not echoed back to the server.
  """
  @spec apply_remote_preferences(Ecto.UUID.t(), map() | nil) :: :ok | {:error, term()}
  def apply_remote_preferences(_project_id, nil), do: :ok

  def apply_remote_preferences(project_id, preferences) do
    with {:ok, project_id} <- UUID.cast(project_id),
         {:ok, %{version: remote_version} = parsed} <- parse_preferences(preferences) do
      if is_nil(remote_version) do
        :ok
      else
        case Repo.get_by(Membership, user_id: Env.local_user_id(), project_id: project_id) do
          nil ->
            :ok

          membership ->
            if newer_version?(remote_version, membership.preferences_updated_at) do
              do_apply_remote_preferences(project_id, membership, parsed)
            else
              :ok
            end
        end
      end
    else
      :error -> {:error, :invalid_preferences}
    end
  end

  @doc """
  Pulls remote nodes for a project until the cursor stops advancing.

  `cursor` defaults to the stored project cursor. Remote preferences are applied
  only after all node batches have been imported.
  """
  @spec pull(Ecto.UUID.t(), String.t() | nil) :: :ok | {:error, term()}
  def pull(project_id, cursor \\ nil) do
    with {:ok, project_id} <- UUID.cast(project_id) do
      do_pull(project_id, cursor || SyncLedger.cursor(project_id), nil)
    else
      :error -> {:error, :invalid_uuid}
    end
  end

  defp do_push_preferences(project_id) do
    case Repo.get_by(Membership, user_id: Env.local_user_id(), project_id: project_id) do
      nil ->
        :ok

      %Membership{preferences_updated_at: nil} ->
        :ok

      %Membership{} = membership ->
        pushed =
          case SyncLedger.preferences_state(project_id) do
            %{pushed_updated_at: pushed_updated_at} -> pushed_updated_at
            nil -> nil
          end

        if newer_version?(membership.preferences_updated_at, pushed) do
          push_local_preferences(project_id, membership)
        else
          :ok
        end
    end
  end

  defp push_local_preferences(project_id, membership) do
    version = membership.preferences_updated_at

    payload = %PushPreferences{
      project_id: project_id,
      active_heads: membership.active_heads || [],
      session_pointer: membership.session_pointer,
      updated_at: DateTime.to_iso8601(version)
    }

    case SyncClient.push_preferences(payload) do
      {:ok, %{preferences: preferences}} ->
        handle_pushed_preferences(project_id, version, preferences)

      {:error, reason} ->
        record_preference_error(project_id, reason)
        {:error, reason}
    end
  end

  defp handle_pushed_preferences(project_id, local_version, preferences) do
    case parse_preferences(preferences) do
      {:ok, %{version: nil}} ->
        mark_preferences_pushed(project_id, local_version)

      {:ok, %{version: remote_version}} ->
        if newer_version?(remote_version, local_version) do
          apply_remote_preferences(project_id, preferences)
        else
          mark_preferences_pushed(project_id, local_version)
        end

      :error ->
        record_preference_error(project_id, :invalid_preferences)
        {:error, :invalid_preferences}
    end
  end

  defp mark_preferences_pushed(project_id, version) do
    case SyncLedger.mark_preferences_pushed(project_id, version) do
      {:ok, _preference} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_preference_error(project_id, reason) do
    case SyncLedger.mark_preferences_error(project_id, reason) do
      {:ok, _preference} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp do_apply_remote_preferences(project_id, membership, parsed) do
    candidates = Enum.uniq(parsed.active_heads ++ List.wrap(parsed.session_pointer))
    existing = Nodes.existing_ids(project_id, candidates)

    active_heads =
      parsed.active_heads
      |> Enum.filter(&MapSet.member?(existing, &1))
      |> Enum.uniq()

    session_pointer =
      case parsed.session_pointer do
        nil ->
          membership.session_pointer

        node_id ->
          if MapSet.member?(existing, node_id),
            do: node_id,
            else: membership.session_pointer
      end

    case membership
         |> Membership.changeset(%{
           active_heads: active_heads,
           session_pointer: session_pointer,
           preferences_updated_at: parsed.version
         })
         |> Repo.update() do
      {:ok, _membership} ->
        case SyncLedger.mark_preferences_remote(project_id, parsed.version) do
          {:ok, _preference} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_preferences(preferences) when is_map(preferences) do
    with {:ok, version} <- parse_version(Map.get(preferences, "updated_at")),
         {:ok, active_heads} <- parse_uuid_list(Map.get(preferences, "active_heads", [])),
         {:ok, session_pointer} <- parse_optional_uuid(Map.get(preferences, "session_pointer")) do
      {:ok,
       %{
         version: version,
         active_heads: active_heads,
         session_pointer: session_pointer
       }}
    end
  end

  defp parse_preferences(_preferences), do: :error

  defp parse_version(nil), do: {:ok, nil}

  defp parse_version(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.shift_zone!(datetime, "Etc/UTC")}
      _ -> :error
    end
  end

  defp parse_version(_value), do: :error

  defp parse_uuid_list(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case UUID.cast(value) do
        {:ok, uuid} -> {:cont, {:ok, [uuid | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  defp parse_uuid_list(_values), do: :error

  defp parse_optional_uuid(nil), do: {:ok, nil}

  defp parse_optional_uuid(value) do
    case UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp newer_version?(_incoming, nil), do: true
  defp newer_version?(incoming, current), do: DateTime.compare(incoming, current) == :gt

  defp provision_if_needed(project) do
    if SyncLedger.provisioned?(project.id) do
      :ok
    else
      with {:ok, _server_project} <- SyncClient.provision(project) do
        SyncLedger.mark_provisioned(project.id)
      end
    end
  end

  defp do_push_pending(project_id) do
    batch = SyncLedger.pushable(project_id, nil, Env.sync_push_limit())

    case batch do
      [] ->
        :ok

      nodes ->
        case push_batch(project_id, nodes) do
          {:ok, 0} -> fail_batch(project_id, nodes, :no_progress)
          {:ok, _pushed} -> do_push_pending(project_id)
          {:error, reason} -> handle_push_error(project_id, nodes, reason)
        end
    end
  end

  defp handle_push_error(project_id, nodes, reason) do
    case failed_node(nodes, reason) do
      nil ->
        fail_batch(project_id, nodes, reason)

      node ->
        case mark_node_failed(node, reason) do
          :ok ->
            Logger.warning(
              "sync isolated node #{node.id} for project #{project_id}: #{inspect(reason)}"
            )

            do_push_pending(project_id)

          {:error, error} ->
            {:error, error}
        end
    end
  end

  defp failed_node(nodes, {:http, status, %{"failed_local_id" => local_id}})
       when status in [409, 422] do
    case UUID.cast(local_id) do
      {:ok, local_id} -> Enum.find(nodes, &(&1.id == local_id))
      :error -> nil
    end
  end

  defp failed_node(_nodes, _reason), do: nil

  defp push_batch(project_id, nodes) do
    with {:ok, git} <- NodeStore.open(project_id),
         {:ok, payload} <- encode_push_nodes(git, nodes),
         {:ok, %{mappings: mappings}} <- SyncClient.push(payload) do
      pending_ids = MapSet.new(nodes, & &1.id)

      pushed_ids =
        mappings
        |> Enum.flat_map(&mapping_id/1)
        |> Enum.filter(&MapSet.member?(pending_ids, &1))
        |> Enum.uniq()

      :ok = SyncLedger.mark_pushed(pushed_ids)
      {:ok, length(pushed_ids)}
    end
  end

  defp encode_push_nodes(git, nodes) do
    nodes
    |> Enum.reduce_while({:ok, []}, fn node, {:ok, acc} ->
      case GitStore.objects_from(git, node.git_commit_sha) do
        {:ok, objects} ->
          {:cont, {:ok, [encode_push_node(node, objects) | acc]}}

        {:error, reason} ->
          {:halt, {:error, {:objects, node.id, reason}}}
      end
    end)
    |> case do
      {:ok, nodes} -> {:ok, Enum.reverse(nodes)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp encode_push_node(node, objects) do
    encoded = NodeCodec.encode_node(node, objects)

    %{
      "local_id" => node.id,
      "git_objects" => encoded["git_objects"],
      "metadata" => Map.drop(encoded, ["id", "git_objects", "created_by"])
    }
  end

  defp mapping_id(%{"local_id" => local_id}), do: [local_id]
  defp mapping_id(_mapping), do: []

  defp fail_batch(project_id, nodes, reason) do
    if reason in [:no_location, :not_configured] do
      {:error, reason}
    else
      if match?({:http, 404, _body}, reason) do
        SyncLedger.clear_provisioned(project_id)
      end

      case mark_nodes_failed(nodes, reason) do
        :ok -> {:error, reason}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp mark_nodes_failed(nodes, reason) do
    Enum.reduce_while(nodes, :ok, fn node, :ok ->
      case mark_node_failed(node, reason) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp mark_node_failed(node, reason) do
    attempt = (SyncLedger.attempts(node.id) || 0) + 1
    retry_at = DateTime.add(DateTime.utc_now(), retry_delay(reason, attempt), :millisecond)

    case SyncLedger.mark_failed(node.id, reason, retry_at) do
      {:ok, _pending} ->
        :ok

      {:error, error} ->
        Logger.warning("failed to record sync failure for #{node.id}: #{inspect(error)}")
        {:error, error}
    end
  end

  defp retry_delay({:http, status, _body}, _attempt) when status in @permanent_statuses do
    @permanent_backoff_ms
  end

  defp retry_delay({:http, status, _body}, _attempt) when status in @config_statuses do
    @config_backoff_ms
  end

  defp retry_delay(_reason, attempt) do
    base = max(Env.sync_retry_backoff_ms(), 1_000)
    cap = max(Env.sync_max_attempts(), 1)
    exponent = min(attempt, cap) - 1
    min(base * Integer.pow(2, exponent), @max_transient_backoff_ms)
  end

  defp do_pull(project_id, cursor, preferences) do
    case pull_batch(project_id, cursor) do
      {:ok, 0, _next, batch_preferences} ->
        apply_remote_preferences(project_id, batch_preferences || preferences)

      {:ok, _count, next, batch_preferences} when next != cursor ->
        do_pull(project_id, next, batch_preferences || preferences)

      {:ok, _count, ^cursor, _preferences} ->
        {:error, :cursor_not_advancing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp pull_batch(project_id, cursor) do
    with {:ok, %{nodes: wires, cursor: next, preferences: preferences}} <-
           SyncClient.pull(project_id, cursor),
         {:ok, git} <- NodeStore.open(project_id),
         {:ok, changesets} <- prepare_nodes(wires, git, project_id),
         :ok <- insert_pulled(changesets, project_id),
         {:ok, _cursor} <- SyncLedger.put_cursor(project_id, next) do
      {:ok, length(wires), next, preferences}
    else
      {:error, reason} -> pull_error(project_id, reason)
    end
  end

  defp prepare_nodes(wires, git, project_id) do
    with {:ok, server_user_id} <- known_server_user() do
      wires
      |> Enum.reduce_while({:ok, []}, fn wire, {:ok, acc} ->
        case prepare_node(wire, git, project_id, server_user_id) do
          {:ok, changeset} -> {:cont, {:ok, [changeset | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, changesets} -> {:ok, Enum.reverse(changesets)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp known_server_user do
    case SyncLedger.server_user_id() do
      nil -> {:error, :server_user_unknown}
      server_user_id -> {:ok, server_user_id}
    end
  end

  defp prepare_node(wire, git, project_id, server_user_id) do
    with {:ok, %{attrs: attrs, objects: objects}} <- NodeCodec.decode_node(wire),
         :ok <- import_objects(git, objects),
         :ok <- ensure_commit_complete(git, attrs.git_commit_sha),
         attrs = map_created_by(attrs, server_user_id),
         %{valid?: true} = changeset <- Node.changeset(attrs),
         true <- Ecto.Changeset.get_field(changeset, :project_id) == project_id do
      {:ok, changeset}
    else
      %{valid?: false} = changeset -> {:error, {:invalid_node, changeset.errors}}
      false -> {:error, :wrong_project}
      {:error, reason} -> {:error, reason}
    end
  end

  defp import_objects(git, objects) do
    case GitStore.import_objects(git, objects) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_objects, reason}}
    end
  end

  defp ensure_commit_complete(git, sha) do
    case GitStore.objects_from(git, sha) do
      {:ok, _objects} -> :ok
      {:error, reason} -> {:error, {:incomplete_commit, reason}}
    end
  end

  defp map_created_by(attrs, server_user_id) do
    if attrs.created_by == server_user_id do
      %{attrs | created_by: Env.local_user_id()}
    else
      attrs
    end
  end

  defp insert_pulled(changesets, project_id) do
    case Repo.transaction(fn ->
           Enum.each(changesets, &insert_pulled_node(&1, project_id))
         end) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_pulled_node(changeset, project_id) do
    id = Ecto.Changeset.get_field(changeset, :id)

    case Repo.get(Node, id) do
      nil ->
        case Repo.insert(changeset) do
          {:ok, _node} -> :ok
          {:error, changeset} -> Repo.rollback({:invalid_node, changeset.errors})
        end

      %Node{} = existing ->
        if same_node?(existing, changeset, project_id) do
          :ok
        else
          Repo.rollback({:node_conflict, id})
        end
    end
  end

  defp same_node?(existing, changeset, project_id) do
    existing.project_id == project_id and
      existing.git_commit_sha == Ecto.Changeset.get_field(changeset, :git_commit_sha) and
      existing.parents == (Ecto.Changeset.get_field(changeset, :parents) || [])
  end

  defp pull_error(project_id, reason) do
    if match?({:http, 404, _body}, reason) do
      SyncLedger.clear_provisioned(project_id)
    end

    {:error, reason}
  end
end
