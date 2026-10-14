defmodule Cadence.Daemon.Watcher do
  @moduledoc """
  Watches a project directory and enqueues a commit after a quiet period.

  Uses `file_system`; bursts of file events are debounced so rapid saves
  collapse into a single commit. On debounce fire, delegates to the project's
  `Cadence.Daemon.CommitQueue`.
  """

  use GenServer

  alias Cadence.Daemon.CommitQueue

  defstruct [:queue, :debounce_ms, :timer]

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
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
  def handle_info({:file_event, _worker, {_path, _events}}, state) do
    {:noreply, schedule_commit(state)}
  end

  def handle_info({:file_event, _worker, :stop}, state) do
    {:noreply, state}
  end

  def handle_info(:debounced_commit, state) do
    CommitQueue.commit(state.queue)
    {:noreply, %{state | timer: nil}}
  end

  defp schedule_commit(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    timer = Process.send_after(self(), :debounced_commit, state.debounce_ms)
    %{state | timer: timer}
  end
end
