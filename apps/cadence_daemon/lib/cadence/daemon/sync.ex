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
    NodeStore,
    ProjectLocation,
    Projects,
    Repo,
    SyncClient,
    SyncLedger
  }

  alias Cadence.Shared.{GitStore, Node, Project, UUID}
  alias Cadence.Shared.Sync.NodeCodec

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
      pull(project_id)
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
  Pulls remote nodes for a project until the cursor stops advancing.

  `cursor` defaults to the stored project cursor.
  """
  @spec pull(Ecto.UUID.t(), String.t() | nil) :: :ok | {:error, term()}
  def pull(project_id, cursor \\ nil) do
    with {:ok, project_id} <- UUID.cast(project_id) do
      do_pull(project_id, cursor || SyncLedger.cursor(project_id))
    else
      :error -> {:error, :invalid_uuid}
    end
  end

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
    batch =
      project_id
      |> SyncLedger.due_pending()
      |> Enum.take(Env.sync_push_limit())

    case batch do
      [] ->
        :ok

      nodes ->
        case push_batch(project_id, nodes) do
          {:ok, 0} -> fail_batch(project_id, nodes, :no_progress)
          {:ok, _pushed} -> do_push_pending(project_id)
          {:error, reason} -> fail_batch(project_id, nodes, reason)
        end
    end
  end

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

      Enum.each(nodes, &mark_node_failed(&1, reason))
      {:error, reason}
    end
  end

  defp mark_node_failed(node, reason) do
    attempt = (SyncLedger.attempts(node.id) || 0) + 1
    retry_at = DateTime.add(DateTime.utc_now(), retry_delay(reason, attempt), :millisecond)

    case SyncLedger.mark_failed(node.id, reason, retry_at) do
      {:ok, _pending} ->
        :ok

      {:error, error} ->
        Logger.warning("failed to record sync failure for #{node.id}: #{inspect(error)}")
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

  defp do_pull(project_id, cursor) do
    case pull_batch(project_id, cursor) do
      {:ok, 0, _next} -> :ok
      {:ok, _count, next} when next != cursor -> do_pull(project_id, next)
      {:ok, _count, ^cursor} -> {:error, :cursor_not_advancing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp pull_batch(project_id, cursor) do
    with {:ok, %{nodes: wires, cursor: next}} <- SyncClient.pull(project_id, cursor),
         {:ok, git} <- NodeStore.open(project_id),
         {:ok, changesets} <- prepare_nodes(wires, git, project_id),
         :ok <- insert_pulled(changesets, project_id),
         {:ok, _cursor} <- SyncLedger.put_cursor(project_id, next) do
      {:ok, length(wires), next}
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
