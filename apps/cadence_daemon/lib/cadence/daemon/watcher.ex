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

  The watcher owns its file-system backend for its whole lifetime instead of
  dying with it. A project directory that is deleted, renamed, or briefly
  unreadable makes `file_system`'s backend crash; a linked watcher would then
  die, the project supervisor would restart it, and sustained restarts could
  exhaust the supervisor's intensity and take the whole project registry down
  with it. Here the backend exit is caught, retried on a slow timer, and the
  watcher resumes when the directory comes back.
  """

  use GenServer

  require Logger

  alias Cadence.Daemon.CommitQueue

  @default_reconnect_ms 5_000

  defstruct [
    :dir,
    :backend,
    :interval,
    :retry_ms,
    :worker,
    :reconnect_timer,
    :last_error,
    :queue,
    :debounce_ms,
    :timer,
    suspended: false,
    pending: false
  ]

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

    # Catching the backend's exit is what keeps a broken project local: without
    # it the linked backend crash kills the watcher and the supervisor restarts
    # it in a tight loop.
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      dir: dir,
      backend: backend,
      interval: Keyword.get(opts, :interval),
      retry_ms: Keyword.get(opts, :reconnect_ms, @default_reconnect_ms),
      queue: queue,
      debounce_ms: debounce_ms
    }

    case open_backend(state) do
      {:ok, worker} ->
        {:ok, %{state | worker: worker}}

      {:error, reason} ->
        # Stay alive and retry. A watcher that stopped here would be restarted
        # by the project supervisor; three failures in five seconds would
        # terminate that supervisor.
        log_failure(state, reason)
        {:ok, schedule_reconnect(%{state | last_error: reason})}
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
  def handle_info({:file_event, worker, {_path, _events}}, %{worker: worker} = state)
      when worker != nil do
    if state.suspended do
      {:noreply, state}
    else
      {:noreply, schedule_commit(state)}
    end
  end

  def handle_info({:file_event, worker, :stop}, %{worker: worker} = state) when worker != nil do
    {:noreply, state}
  end

  # A late event from a backend that already died.
  def handle_info({:file_event, _worker, _event}, state), do: {:noreply, state}

  def handle_info({:EXIT, worker, reason}, %{worker: worker} = state) when worker != nil do
    Logger.warning("watcher backend for #{state.dir} exited: #{summarize_exit(reason)}; retrying")

    {:noreply, schedule_reconnect(%{state | worker: nil, last_error: reason})}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(:reconnect, %{worker: nil} = state) do
    state = %{state | reconnect_timer: nil}

    case open_backend(state) do
      {:ok, worker} ->
        Logger.info("watcher resumed for #{state.dir}")
        {:noreply, %{state | worker: worker, last_error: nil}}

      {:error, reason} ->
        if reason != state.last_error, do: log_failure(state, reason)
        {:noreply, schedule_reconnect(%{state | last_error: reason})}
    end
  end

  def handle_info(:reconnect, state), do: {:noreply, state}

  def handle_info(:debounced_commit, %{suspended: true} = state) do
    {:noreply, %{state | timer: nil}}
  end

  def handle_info(:debounced_commit, state) do
    # A debounce can outlive the directory (delete/rename); committing then
    # would crash the queue on a snapshot error. Wait for the watcher to
    # reconnect instead.
    if File.dir?(state.dir) do
      CommitQueue.commit(state.queue, :auto, skip_unchanged: true)
    end

    {:noreply, %{state | timer: nil}}
  end

  @impl true
  def terminate(_reason, %{worker: worker}) when is_pid(worker) do
    # The backend is linked, so it follows this process down; stopping it
    # explicitly keeps shutdown ordering deterministic.
    Process.exit(worker, :shutdown)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp open_backend(%{dir: dir} = state) do
    if File.dir?(dir) do
      fs_opts = [dirs: [dir], backend: state.backend]

      fs_opts =
        case state.interval do
          nil -> fs_opts
          interval -> Keyword.put(fs_opts, :interval, interval)
        end

      case start_backend(fs_opts) do
        {:ok, worker} ->
          FileSystem.subscribe(worker)
          {:ok, worker}

        :ignore ->
          {:error, :no_file_system_backend}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :no_such_directory}
    end
  end

  defp start_backend(fs_opts) do
    FileSystem.start_link(fs_opts)
  rescue
    exception -> {:error, exception}
  end

  defp log_failure(state, reason) do
    Logger.warning(
      "watcher for #{state.dir} unavailable (#{inspect(reason)}); retrying every #{state.retry_ms} ms"
    )
  end

  # A crashed GenServer reports `{exception, stacktrace}`; log the message, not
  # the whole stack, so one missing directory does not flood the daemon log.
  defp summarize_exit({%{__struct__: _} = exception, _stacktrace}) do
    Exception.message(exception)
  end

  defp summarize_exit(reason), do: inspect(reason)

  defp schedule_reconnect(%{reconnect_timer: nil} = state) do
    %{state | reconnect_timer: Process.send_after(self(), :reconnect, state.retry_ms)}
  end

  defp schedule_reconnect(state), do: state

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
