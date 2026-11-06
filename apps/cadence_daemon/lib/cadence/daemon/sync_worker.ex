defmodule Cadence.Daemon.SyncWorker do
  @moduledoc """
  Background sync scheduler.

  One `SyncWorker` owns the periodic pass and the in-flight project set. Each
  project's network cycle runs in a `Cadence.Daemon.SyncTasks` task, so a slow
  or failing server never blocks commits or the daemon API.
  """

  use GenServer

  require Logger

  alias Cadence.Daemon.{DocQueue, Env, Projects, Sync, SyncClient}

  @tasks Cadence.Daemon.SyncTasks

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Runs a pass over every registered project (subject to config/in-flight)."
  def wake_all do
    GenServer.cast(__MODULE__, :wake_all)
  end

  @doc "Wakes the worker for one project (used after enqueueing a node)."
  def wake(project_id) do
    GenServer.cast(__MODULE__, {:wake, project_id})
  end

  @impl true
  def init(_opts) do
    schedule_tick()
    {:ok, %{in_flight: %{}, last_status: %{}}}
  end

  @impl true
  def handle_cast(:wake_all, state) do
    {:noreply, start_projects(project_ids(), state)}
  end

  def handle_cast({:wake, project_id}, state) do
    {:noreply, start_project(project_id, state)}
  end

  @impl true
  def handle_info(:tick, state) do
    schedule_tick()
    {:noreply, start_projects(project_ids(), state)}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(ref, result, state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {:noreply, finish(ref, {:exit, reason}, state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule_tick do
    Process.send_after(self(), :tick, max(Env.sync_interval_ms(), 1_000))
  end

  defp project_ids do
    if sync_ready?(), do: Projects.list_project_ids(), else: []
  end

  defp start_projects(project_ids, state) do
    Enum.reduce(project_ids, state, &start_project/2)
  end

  defp start_project(project_id, state) do
    cond do
      not sync_ready?() ->
        state

      project_in_flight?(state, project_id) ->
        state

      true ->
        task = Task.Supervisor.async_nolink(@tasks, fn -> Sync.sync(project_id) end)
        in_flight = Map.put(state.in_flight, task.ref, %{project_id: project_id})
        %{state | in_flight: in_flight}
    end
  end

  defp finish(ref, result, state) do
    case Map.pop(state.in_flight, ref) do
      {nil, _in_flight} ->
        state

      {%{project_id: project_id}, in_flight} ->
        log_result(project_id, result)
        retry_deferred_docs(project_id, result, state.last_status)
        last_status = Map.put(state.last_status, project_id, status(result))
        %{state | in_flight: in_flight, last_status: last_status}
    end
  end

  # Connectivity returned for this project: give deferred doc jobs another
  # chance (spec §9.5). A per-project transition guard keeps a permanently
  # failing job from being retried on every pass.
  defp retry_deferred_docs(project_id, :ok = _result, last_status) do
    if Map.get(last_status, project_id) != :ok, do: DocQueue.retry_pending(project_id)
  end

  defp retry_deferred_docs(_project_id, _result, _last_status), do: :ok

  defp status(:ok), do: :ok
  defp status(_result), do: :error

  defp project_in_flight?(state, project_id) do
    Enum.any?(state.in_flight, fn {_ref, entry} -> entry.project_id == project_id end)
  end

  defp sync_ready? do
    Env.sync_enabled?() and SyncClient.configured?()
  end

  defp log_result(_project_id, :ok), do: :ok
  defp log_result(_project_id, {:exit, :normal}), do: :ok

  defp log_result(project_id, {:error, reason}) do
    Logger.warning("sync failed for project #{project_id}: #{inspect(reason)}")
  end

  defp log_result(project_id, {:exit, reason}) do
    Logger.warning("sync task for project #{project_id} exited: #{inspect(reason)}")
  end
end
