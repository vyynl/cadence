defmodule Cadence.Daemon.ProjectRegistry do
  @moduledoc """
  Supervises one `Cadence.Daemon.ProjectSupervisor` per registered project.

  Each project supervisor owns its `{CommitQueue, Watcher}` pair. The commit
  queue is registered under `Cadence.Daemon.Queues` keyed by `project_id` so
  callers (e.g. the API) can reach it via `lookup_queue/1`.

  Project supervisors are started with `restart: :transient`. A project whose
  own supervision collapses (for example a commit queue that cannot stop
  crashing) is dropped instead of being restarted in a loop; otherwise its
  restarts would count against this supervisor's own intensity and could
  terminate the registry, silently stopping every other project. A dropped
  project is restored by re-registering it or by the boot rehydrate.
  """

  use DynamicSupervisor

  alias Cadence.Daemon.ProjectSupervisor

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Boots the `{CommitQueue, Watcher}` pair for a project. Returns
  `{:ok, supervisor_pid}`.
  """
  def start_project(opts) do
    spec = Supervisor.child_spec({ProjectSupervisor, opts}, restart: :transient)
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @doc """
  Stops a project's supervisor and its queue/watcher.

  Used by tests and by a caller that wants to drop a project without
  re-registering it. Returns `:ok` when the project is not running.
  """
  @spec stop_project(Ecto.UUID.t()) :: :ok
  def stop_project(project_id) do
    case find_child(project_id) do
      nil ->
        :ok

      pid ->
        _ = DynamicSupervisor.terminate_child(__MODULE__, pid)
        :ok
    end
  end

  @doc "Returns the commit-queue pid for `project_id`, or `nil` if not registered."
  @spec lookup_queue(Ecto.UUID.t()) :: pid() | nil
  def lookup_queue(project_id) do
    GenServer.whereis({:via, Registry, {Cadence.Daemon.Queues, project_id}})
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  defp find_child(project_id) do
    # A DynamicSupervisor reports `:undefined` as every child id, so identify a
    # project's supervisor by the queue process it owns.
    queue = lookup_queue(project_id)

    if is_pid(queue) do
      Enum.find_value(DynamicSupervisor.which_children(__MODULE__), fn
        {_id, pid, :supervisor, _modules} when is_pid(pid) ->
          if queue_child?(pid, queue), do: pid

        _other ->
          nil
      end)
    end
  end

  defp queue_child?(supervisor, queue) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.any?(fn {_id, pid, _type, _modules} -> pid == queue end)
  catch
    :exit, _reason -> false
  end
end
