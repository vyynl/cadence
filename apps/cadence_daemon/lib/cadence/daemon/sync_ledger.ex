defmodule Cadence.Daemon.SyncLedger do
  @moduledoc """
  Persistent daemon sync state: nodes waiting to upload, per-project pull
  cursors, and small global sync metadata (server user ID, backfill marker).

  The ledger owns all writes so callers never race on SQLite. Commits enqueue
  asynchronously; the network worker (added in a later slice) reads
  `due_pending/2` and reports success/failure back here.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias Cadence.Daemon.{
    Env,
    Repo,
    SyncClient,
    SyncCursor,
    SyncPending,
    SyncPreference,
    SyncState
  }

  alias Cadence.Shared.{Node, UUID}

  @backfill_key "backfill_v1"
  @server_user_key "server_user_id"
  @provisioned_prefix "provisioned:"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Queues a node for upload. Idempotent for a given node ID."
  @spec enqueue(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def enqueue(project_id, node_id) do
    GenServer.cast(__MODULE__, {:enqueue, project_id, node_id, sync_ready?()})
  end

  @doc "All pending nodes for a project, ordered parents-first."
  @spec pending(Ecto.UUID.t()) :: [Node.t()]
  def pending(project_id) do
    GenServer.call(__MODULE__, {:pending, project_id})
  end

  @doc "Pending nodes whose retry time has arrived, ordered parents-first."
  @spec due_pending(Ecto.UUID.t(), DateTime.t()) :: [Node.t()]
  def due_pending(project_id, now \\ DateTime.utc_now()) do
    GenServer.call(__MODULE__, {:due_pending, project_id, now})
  end

  @doc """
  Returns up to `limit` pushable nodes in parents-first order.

  A node is pushable when it is due and every parent is either not pending
  locally or has already been selected in this pass. This keeps descendants of
  a backed-off parent pending instead of failing them as out-of-order.
  """
  @spec pushable(Ecto.UUID.t(), DateTime.t() | nil, pos_integer()) :: [Node.t()]
  def pushable(project_id, now \\ nil, limit \\ 100) do
    GenServer.call(__MODULE__, {:pushable, project_id, now, limit})
  end

  @doc "Project IDs with at least one due pending node."
  @spec pending_projects(DateTime.t()) :: [Ecto.UUID.t()]
  def pending_projects(now \\ DateTime.utc_now()) do
    GenServer.call(__MODULE__, {:pending_projects, now})
  end

  @doc "Removes pushed nodes from the pending queue."
  @spec mark_pushed(Ecto.UUID.t() | [Ecto.UUID.t()]) :: :ok
  def mark_pushed(node_ids) do
    GenServer.call(__MODULE__, {:mark_pushed, List.wrap(node_ids)})
  end

  @doc """
  Records a failed upload: increments attempts, stores the error, and schedules
  the next retry.
  """
  @spec mark_failed(Ecto.UUID.t(), term(), DateTime.t()) ::
          {:ok, SyncPending.t()} | {:error, term()}
  def mark_failed(node_id, reason, next_attempt_at) do
    GenServer.call(__MODULE__, {:mark_failed, node_id, reason, next_attempt_at})
  end

  @doc "The project's pull cursor, or `nil` before the first pull."
  @spec cursor(Ecto.UUID.t()) :: String.t() | nil
  def cursor(project_id) do
    GenServer.call(__MODULE__, {:cursor, project_id})
  end

  @doc "Stores the project's pull cursor."
  @spec put_cursor(Ecto.UUID.t(), String.t()) ::
          {:ok, SyncCursor.t()} | {:error, term()}
  def put_cursor(project_id, cursor) do
    GenServer.call(__MODULE__, {:put_cursor, project_id, cursor})
  end

  @doc """
  The project's preference sync state, or `nil` before any preference sync.
  """
  @spec preferences_state(Ecto.UUID.t()) ::
          %{
            pushed_updated_at: DateTime.t() | nil,
            remote_updated_at: DateTime.t() | nil,
            last_error: String.t() | nil
          }
          | nil
  def preferences_state(project_id) do
    GenServer.call(__MODULE__, {:preferences_state, project_id})
  end

  @doc "Records the local preference version accepted by the server."
  @spec mark_preferences_pushed(Ecto.UUID.t(), DateTime.t()) ::
          {:ok, SyncPreference.t()} | {:error, term()}
  def mark_preferences_pushed(project_id, version) do
    GenServer.call(__MODULE__, {:mark_preferences_pushed, project_id, version})
  end

  @doc "Records a remote preference version applied locally."
  @spec mark_preferences_remote(Ecto.UUID.t(), DateTime.t()) ::
          {:ok, SyncPreference.t()} | {:error, term()}
  def mark_preferences_remote(project_id, version) do
    GenServer.call(__MODULE__, {:mark_preferences_remote, project_id, version})
  end

  @doc "Records a preference sync failure without clearing the local version."
  @spec mark_preferences_error(Ecto.UUID.t(), term()) ::
          {:ok, SyncPreference.t()} | {:error, term()}
  def mark_preferences_error(project_id, reason) do
    GenServer.call(__MODULE__, {:mark_preferences_error, project_id, reason})
  end

  @doc "Wakes the sync worker after a local preference change when sync is ready."
  @spec preferences_changed(Ecto.UUID.t()) :: :ok
  def preferences_changed(project_id) do
    if sync_ready?() do
      GenServer.cast(__MODULE__, {:preferences_changed, project_id})
    else
      :ok
    end
  end

  @doc "The authenticated server user ID, or `nil` before `/sync/me` succeeds."
  @spec server_user_id() :: Ecto.UUID.t() | nil
  def server_user_id do
    GenServer.call(__MODULE__, :server_user_id)
  end

  @doc "Stores the authenticated server user ID."
  @spec put_server_user_id(Ecto.UUID.t()) :: {:ok, Ecto.UUID.t()} | {:error, term()}
  def put_server_user_id(server_user_id) do
    GenServer.call(__MODULE__, {:put_server_user_id, server_user_id})
  end

  @doc "Whether this project has been provisioned on the configured server."
  @spec provisioned?(Ecto.UUID.t()) :: boolean()
  def provisioned?(project_id) do
    GenServer.call(__MODULE__, {:provisioned?, project_id})
  end

  @doc "Marks a project as provisioned on the configured server."
  @spec mark_provisioned(Ecto.UUID.t()) :: :ok | {:error, :invalid_uuid}
  def mark_provisioned(project_id) do
    GenServer.call(__MODULE__, {:mark_provisioned, project_id})
  end

  @doc "Clears the provisioned marker (e.g. after the server loses the project)."
  @spec clear_provisioned(Ecto.UUID.t()) :: :ok | {:error, :invalid_uuid}
  def clear_provisioned(project_id) do
    GenServer.call(__MODULE__, {:clear_provisioned, project_id})
  end

  @doc "The pending node's attempt count, or `nil` if it is not queued."
  @spec attempts(Ecto.UUID.t()) :: non_neg_integer() | nil
  def attempts(node_id) do
    GenServer.call(__MODULE__, {:attempts, node_id})
  end

  @doc """
  Ensures local-only nodes are queued. Runs once, then marks the backfill
  complete. `force: true` re-runs it (tests/recovery).
  """
  @spec rehydrate(keyword()) :: :ok
  def rehydrate(opts \\ []) do
    GenServer.call(__MODULE__, {:rehydrate, opts}, :infinity)
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_cast({:enqueue, project_id, node_id, ready?}, state) do
    with {:ok, project_id} <- UUID.cast(project_id),
         {:ok, node_id} <- UUID.cast(node_id) do
      now = DateTime.utc_now()

      case %SyncPending{
             node_id: node_id,
             project_id: project_id,
             enqueued_at: now,
             attempts: 0,
             next_attempt_at: now
           }
           |> Repo.insert(on_conflict: :nothing) do
        {:ok, _pending} ->
          if ready?, do: notify_worker(project_id)

        {:error, reason} ->
          Logger.error("failed to enqueue node #{node_id} for sync: #{inspect(reason)}")
      end
    else
      _ -> Logger.warning("ignoring sync enqueue with invalid ids")
    end

    {:noreply, state}
  end

  def handle_cast({:preferences_changed, project_id}, state) do
    case UUID.cast(project_id) do
      {:ok, project_id} ->
        notify_worker(project_id)

      :error ->
        Logger.warning("ignoring preference change with an invalid project id")
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:pending, project_id}, _from, state) do
    {:reply, pending_nodes(project_id, nil), state}
  end

  def handle_call({:due_pending, project_id, now}, _from, state) do
    {:reply, pending_nodes(project_id, now), state}
  end

  def handle_call({:pushable, project_id, now, limit}, _from, state) do
    {:reply, pushable_nodes(project_id, now || DateTime.utc_now(), limit), state}
  end

  def handle_call({:pending_projects, now}, _from, state) do
    projects =
      SyncPending
      |> where([p], p.next_attempt_at <= ^now)
      |> distinct(true)
      |> select([p], p.project_id)
      |> Repo.all()

    {:reply, projects, state}
  end

  def handle_call({:mark_pushed, node_ids}, _from, state) do
    ids = node_ids |> Enum.map(&cast_uuid/1) |> Enum.reject(&is_nil/1)

    if ids != [] do
      Repo.delete_all(from(p in SyncPending, where: p.node_id in ^ids))
    end

    {:reply, :ok, state}
  end

  def handle_call({:mark_failed, node_id, reason, next_attempt_at}, _from, state) do
    reply =
      with {:ok, node_id} <- UUID.cast(node_id),
           %SyncPending{} = pending <- Repo.get(SyncPending, node_id) do
        pending
        |> SyncPending.changeset(%{
          attempts: pending.attempts + 1,
          last_error: format_error(reason),
          next_attempt_at: next_attempt_at
        })
        |> Repo.update()
      else
        nil -> {:error, :not_found}
        :error -> {:error, :invalid_uuid}
      end

    {:reply, reply, state}
  end

  def handle_call({:cursor, project_id}, _from, state) do
    reply =
      with {:ok, project_id} <- UUID.cast(project_id),
           %SyncCursor{} = cursor <- Repo.get(SyncCursor, project_id) do
        cursor.cursor
      else
        _ -> nil
      end

    {:reply, reply, state}
  end

  def handle_call({:put_cursor, project_id, cursor}, _from, state) do
    reply =
      with {:ok, project_id} <- UUID.cast(project_id),
           true <- is_binary(cursor) do
        now = DateTime.utc_now()

        %SyncCursor{project_id: project_id, cursor: cursor, updated_at: now}
        |> Repo.insert(
          on_conflict: {:replace, [:cursor, :updated_at]},
          conflict_target: :project_id
        )
      else
        :error -> {:error, :invalid_uuid}
        false -> {:error, :invalid_cursor}
      end

    {:reply, reply, state}
  end

  def handle_call({:preferences_state, project_id}, _from, state) do
    reply =
      with {:ok, project_id} <- UUID.cast(project_id),
           %SyncPreference{} = preference <- Repo.get(SyncPreference, project_id) do
        %{
          pushed_updated_at: preference.pushed_updated_at,
          remote_updated_at: preference.remote_updated_at,
          last_error: preference.last_error
        }
      else
        _ -> nil
      end

    {:reply, reply, state}
  end

  def handle_call({:mark_preferences_pushed, project_id, version}, _from, state) do
    reply =
      put_preferences(project_id, %{
        pushed_updated_at: version,
        remote_updated_at: version,
        last_error: nil
      })

    {:reply, reply, state}
  end

  def handle_call({:mark_preferences_remote, project_id, version}, _from, state) do
    reply =
      put_preferences(project_id, %{
        pushed_updated_at: version,
        remote_updated_at: version,
        last_error: nil
      })

    {:reply, reply, state}
  end

  def handle_call({:mark_preferences_error, project_id, reason}, _from, state) do
    {:reply, put_preferences(project_id, %{last_error: format_error(reason)}), state}
  end

  def handle_call(:server_user_id, _from, state) do
    {:reply, state_value(@server_user_key), state}
  end

  def handle_call({:put_server_user_id, server_user_id}, _from, state) do
    reply =
      with {:ok, server_user_id} <- UUID.cast(server_user_id) do
        put_state(@server_user_key, server_user_id)
        {:ok, server_user_id}
      else
        :error -> {:error, :invalid_uuid}
      end

    {:reply, reply, state}
  end

  def handle_call({:provisioned?, project_id}, _from, state) do
    reply =
      with {:ok, project_id} <- UUID.cast(project_id) do
        state_value(provisioned_key(project_id)) == "true"
      else
        :error -> false
      end

    {:reply, reply, state}
  end

  def handle_call({:mark_provisioned, project_id}, _from, state) do
    reply =
      with {:ok, project_id} <- UUID.cast(project_id) do
        put_state(provisioned_key(project_id), "true")
        :ok
      else
        :error -> {:error, :invalid_uuid}
      end

    {:reply, reply, state}
  end

  def handle_call({:clear_provisioned, project_id}, _from, state) do
    reply =
      with {:ok, project_id} <- UUID.cast(project_id) do
        case Repo.get(SyncState, provisioned_key(project_id)) do
          nil ->
            :ok

          row ->
            Repo.delete(row)
            :ok
        end
      else
        :error -> {:error, :invalid_uuid}
      end

    {:reply, reply, state}
  end

  def handle_call({:attempts, node_id}, _from, state) do
    reply =
      with {:ok, node_id} <- UUID.cast(node_id),
           %SyncPending{attempts: attempts} <- Repo.get(SyncPending, node_id) do
        attempts
      else
        _ -> nil
      end

    {:reply, reply, state}
  end

  def handle_call({:rehydrate, opts}, _from, state) do
    {:reply, backfill(Keyword.get(opts, :force, false)), state}
  end

  defp pushable_nodes(project_id, now, limit) do
    with {:ok, project_id} <- UUID.cast(project_id),
         true <- is_integer(limit) and limit > 0 do
      rows =
        from(n in Node,
          join: p in SyncPending,
          on: p.node_id == n.id,
          where: p.project_id == ^project_id and n.project_id == ^project_id,
          order_by: [asc: n.created_at, asc: n.id],
          select: {n, p.next_attempt_at}
        )
        |> Repo.all()

      pending_ids = MapSet.new(rows, fn {node, _next_attempt_at} -> node.id end)

      {selected, _selected_ids} =
        Enum.reduce(rows, {[], MapSet.new()}, fn {node, next_attempt_at},
                                                 {selected, selected_ids} ->
          if due?(next_attempt_at, now) and
               parents_selected?(node.parents || [], pending_ids, selected_ids) do
            {[node | selected], MapSet.put(selected_ids, node.id)}
          else
            {selected, selected_ids}
          end
        end)

      selected
      |> Enum.reverse()
      |> Enum.take(limit)
    else
      _ -> []
    end
  end

  defp due?(next_attempt_at, now), do: DateTime.compare(next_attempt_at, now) != :gt

  defp parents_selected?(parents, pending_ids, selected_ids) do
    Enum.all?(parents, fn parent ->
      not MapSet.member?(pending_ids, parent) or MapSet.member?(selected_ids, parent)
    end)
  end

  defp pending_nodes(project_id, now) do
    with {:ok, project_id} <- UUID.cast(project_id) do
      query =
        from(n in Node,
          join: p in SyncPending,
          on: p.node_id == n.id,
          where: p.project_id == ^project_id
        )

      query =
        if now do
          where(query, [n, p], p.next_attempt_at <= ^now)
        else
          query
        end

      query
      |> order_by([n], asc: n.created_at, asc: n.id)
      |> select([n], n)
      |> Repo.all()
    else
      :error -> []
    end
  end

  defp backfill(force) do
    if not force and state_value(@backfill_key) do
      :ok
    else
      now = DateTime.utc_now()

      rows =
        Node
        |> Repo.all()
        |> Enum.map(fn node ->
          at = node.created_at || now

          %{
            node_id: node.id,
            project_id: node.project_id,
            enqueued_at: at,
            attempts: 0,
            last_error: nil,
            next_attempt_at: at
          }
        end)

      if rows != [] do
        Repo.insert_all(SyncPending, rows, on_conflict: :nothing)
      end

      put_state(@backfill_key, "done")
      :ok
    end
  end

  defp put_preferences(project_id, attrs) do
    with {:ok, project_id} <- UUID.cast(project_id),
         :ok <- validate_preference_attrs(attrs) do
      now = DateTime.utc_now()
      fields = [:updated_at | Map.keys(attrs)]

      case %SyncPreference{project_id: project_id}
           |> SyncPreference.changeset(
             Map.merge(attrs, %{project_id: project_id, updated_at: now})
           )
           |> Repo.insert(on_conflict: {:replace, fields}, conflict_target: :project_id) do
        {:ok, _preference} -> {:ok, Repo.get!(SyncPreference, project_id)}
        {:error, _changeset} = error -> error
      end
    else
      :error -> {:error, :invalid_uuid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_preference_attrs(%{
         pushed_updated_at: %DateTime{},
         remote_updated_at: %DateTime{}
       }),
       do: :ok

  defp validate_preference_attrs(%{last_error: error}) when is_binary(error), do: :ok
  defp validate_preference_attrs(_attrs), do: {:error, :invalid_preference_state}

  defp state_value(key) do
    case Repo.get(SyncState, key) do
      %SyncState{value: value} -> value
      nil -> nil
    end
  end

  defp put_state(key, value) do
    now = DateTime.utc_now()

    %SyncState{key: key, value: value, updated_at: now}
    |> Repo.insert!(
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: :key
    )
  end

  defp provisioned_key(project_id), do: @provisioned_prefix <> project_id

  defp notify_worker(project_id) do
    if sync_ready?(), do: Cadence.Daemon.SyncWorker.wake(project_id)
  end

  defp sync_ready? do
    Env.sync_enabled?() and SyncClient.configured?() and
      Process.whereis(Cadence.Daemon.SyncWorker) != nil
  end

  defp cast_uuid(value) do
    case UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp format_error(reason) do
    reason
    |> inspect(limit: 20, printable_limit: 1_000)
    |> String.slice(0, 1_000)
  end
end
