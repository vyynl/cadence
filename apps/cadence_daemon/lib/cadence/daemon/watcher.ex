defmodule Cadence.Daemon.Watcher do
  @moduledoc """
  Watches a project directory and enqueues a commit after a quiet period.

  Uses `file_system`; bursts of file events are debounced so rapid saves
  collapse into a single commit. On debounce fire, delegates to the project's
  `Cadence.Daemon.CommitQueue`.

  A project's watcher is registered in `Cadence.Daemon.Queues` so background
  writers (the doc agent) can `suspend/1` it while they rewrite the working
  tree. Events seen while suspended are dropped, and `resume/1` re-arms a
  debounce that was already pending (a user edit is never lost), so an
  automated write cannot create a second node (spec §9.3).
  """

  use GenServer

  alias Cadence.Daemon.CommitQueue

  defstruct [:queue, :debounce_ms, :timer, suspended: false, pending: false]

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Suspends commits for a project. No-op when the project has no running
  watcher.
  """
  @spec suspend(Ecto.UUID.t()) :: :ok
  def suspend(project_id), do: control(project_id, :suspend)

  @doc """
  Resumes commits for a project, discarding any debounce timer armed before the
  suspension. No-op when the project has no running watcher.
  """
  @spec resume(Ecto.UUID.t()) :: :ok
  def resume(project_id), do: control(project_id, :resume)

  @doc "Whether a project's watcher is currently suspended (`false` when absent)."
  @spec suspended?(Ecto.UUID.t()) :: boolean()
  def suspended?(project_id) do
    case lookup(project_id) do
      nil -> false
      pid -> GenServer.call(pid, :suspended?)
    end
  end

  @impl true
  def init(opts) do
    dir = Keyword.fetch!(opts, :dir)
    queue = Keyword.fetch!(opts, :commit_queue)

    debounce_ms =
      Keyword.get(
        opts,
        :debounce_ms,
        Application.get_env(:cadence_daemon, :watch_debounce_ms, 2000)
      )

    backend =
      Keyword.get(
        opts,
        :backend,
        Application.get_env(:cadence_daemon, :watch_backend, :fs_inotify)
      )

    fs_opts = [dirs: [dir], backend: backend]

    fs_opts =
      case Keyword.get(opts, :interval) do
        nil -> fs_opts
        interval -> Keyword.put(fs_opts, :interval, interval)
      end

    case FileSystem.start_link(fs_opts) do
      {:ok, worker} ->
        FileSystem.subscribe(worker)
        {:ok, %__MODULE__{queue: queue, debounce_ms: debounce_ms, timer: nil}}

      :ignore ->
        {:stop, :no_file_system_backend}
    end
  end

  @impl true
  def handle_call(:suspend, _from, state) do
    # Remember a debounce that was already armed so `resume/1` can re-arm it;
    # a user edit must not be lost while the doc agent rewrites the tree.
    pending = state.pending or state.timer != nil
    {:reply, :ok, %{cancel_timer(state) | suspended: true, pending: pending}}
  end

  def handle_call(:resume, _from, state) do
    state = %{state | suspended: false}

    state =
      if state.pending do
        schedule_commit(%{state | pending: false})
      else
        state
      end

    {:reply, :ok, state}
  end

  def handle_call(:suspended?, _from, state) do
    {:reply, state.suspended, state}
  end

  @impl true
  def handle_info({:file_event, _worker, {_path, _events}}, %{suspended: true} = state) do
    {:noreply, state}
  end

  def handle_info({:file_event, _worker, {_path, _events}}, state) do
    {:noreply, schedule_commit(state)}
  end

  def handle_info({:file_event, _worker, :stop}, state) do
    {:noreply, state}
  end

  def handle_info(:debounced_commit, %{suspended: true} = state) do
    {:noreply, %{state | timer: nil}}
  end

  def handle_info(:debounced_commit, state) do
    CommitQueue.commit(state.queue, :auto, skip_unchanged: true)
    {:noreply, %{state | timer: nil}}
  end

  defp schedule_commit(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    timer = Process.send_after(self(), :debounced_commit, state.debounce_ms)
    %{state | timer: timer}
  end

  defp cancel_timer(%__MODULE__{timer: nil} = state), do: state

  defp cancel_timer(%__MODULE__{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp control(project_id, message) do
    case lookup(project_id) do
      nil -> :ok
      pid -> GenServer.call(pid, message)
    end
  end

  defp lookup(project_id) do
    GenServer.whereis({:via, Registry, {Cadence.Daemon.Queues, {:watcher, project_id}}})
  end
end
