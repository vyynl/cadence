defmodule Cadence.Server.Storage.Repacker do
  @moduledoc """
  Queue, push trigger, and periodic backstop for `Cadence.Server.Storage`
  (spec §13 Phase 7b, §16).

  One repack runs at a time (`CAD_REPACK_MIN_*` decide *whether* a project is
  due; this process only bounds concurrency). Each project appears at most once
  in the queue, whether it arrived from a push trigger or the backstop.

  Push-triggered checks are cooled down after a failure for one
  `CAD_REPACK_INTERVAL_MS`, so a broken store is not retried on every push. The
  backstop enqueues every project every interval and bypasses the cooldown, so
  it is the retry path. A `{:error, :busy}` result means another process (or the
  CLI) holds the project lock and is not recorded as a failure.

  A run is bounded by `CAD_REPACK_TIMEOUT_MS` (`Storage.run_timeout_ms/0`; `0`
  disables). A task past the bound is killed: the run body holds a
  transaction-scoped advisory lock, so the kill rolls the transaction back and
  returns its pooled connection, and the next queued project starts. Killing is
  safe because pack writes are `.tmp` + verify + rename (the next run's grace
  sweep removes debris) and the pack phase never deletes anything: a loose copy
  is unlinked only by a later sweep, after re-reading and re-hashing it through
  an existing pack. A timeout counts as a failure for the push cooldown, so a
  pathological store is retried by the backstop, not on every push.

  The runner is resolved per run from
  `Application.get_env(:cadence_server, :repack_runner, &Storage.run_if_needed/1)`
  so tests can observe scheduling without touching a store (the same injection
  pattern as `:meld_llm` and `:actions_docker`). Cross-process serialization is
  the storage-level advisory lock, not this queue. Queue and cooldown state are
  in-memory; a restart re-derives them from the next trigger or backstop.
  """

  use GenServer

  require Logger

  alias Cadence.Server.Storage
  alias Cadence.Server.Storage.TaskSupervisor

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Queue a threshold check for `project_id`.

  `:server` selects the Repacker instance (default `#{inspect(__MODULE__)}`).
  """
  @spec schedule(String.t(), keyword()) :: :ok
  def schedule(project_id, opts \\ []) when is_binary(project_id) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.cast(server, {:schedule, project_id})
  end

  @impl true
  def init(opts) do
    state = %{
      projects: Keyword.get(opts, :projects, &Storage.project_ids/0),
      runner: Keyword.get(opts, :runner),
      interval_ms: Keyword.get(opts, :interval_ms, Storage.interval_ms()),
      cooldown_ms: Keyword.get(opts, :cooldown_ms, Storage.interval_ms()),
      timeout_ms: Keyword.get(opts, :timeout_ms, Storage.run_timeout_ms()),
      queue: :queue.new(),
      queued: MapSet.new(),
      running: nil,
      failed_at: %{}
    }

    {:ok, schedule_backstop(state)}
  end

  @impl true
  def handle_cast({:schedule, project_id}, state) do
    cond do
      running?(state, project_id) -> {:noreply, state}
      MapSet.member?(state.queued, project_id) -> {:noreply, state}
      cooling_down?(state, project_id) -> {:noreply, state}
      true -> {:noreply, state |> enqueue(project_id) |> start_next()}
    end
  end

  @impl true
  def handle_info({ref, result}, %{running: %{ref: ref} = running} = state) do
    Process.demonitor(ref, [:flush])
    disarm_timeout(running.timer)
    state = %{state | running: nil}
    {:noreply, state |> finish(running.project_id, result) |> start_next()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running: %{ref: ref} = running} = state) do
    disarm_timeout(running.timer)

    Logger.warning(
      "repack task crashed project=#{running.project_id} class=#{inspect(crash_class(reason))}"
    )

    state = %{state | running: nil}
    {:noreply, state |> finish(running.project_id, {:error, :crashed}) |> start_next()}
  end

  # A run past its bound is cancelled, never awaited: a cooperative deadline
  # cannot interrupt a single hung batch. The demonitor + kill pair means the
  # `:DOWN` is dropped, so the timeout is recorded exactly once.
  def handle_info({:repack_timeout, ref}, %{running: %{ref: ref} = running} = state) do
    if Process.alive?(running.pid) do
      Process.demonitor(ref, [:flush])
      Process.exit(running.pid, :kill)
      state = %{state | running: nil}
      {:noreply, state |> finish(running.project_id, {:error, :timeout}) |> start_next()}
    else
      # The run finished at the deadline; its result or `:DOWN` is queued and
      # handled normally, with the correct outcome. A task that has sent its
      # result but not yet exited is still alive and is treated as timed out:
      # the cost is one cooldown interval and the work is idempotent.
      {:noreply, state}
    end
  end

  def handle_info(:backstop, state) do
    state =
      case list_projects(state.projects) do
        {:ok, project_ids} -> Enum.reduce(project_ids, state, &enqueue(&2, &1))
        {:error, _reason} -> state
      end

    {:noreply, state |> start_next() |> schedule_backstop()}
  end

  def handle_info(_message, state), do: {:noreply, state}

  ## Queue

  defp enqueue(state, project_id) do
    if MapSet.member?(state.queued, project_id) or running?(state, project_id) do
      state
    else
      %{
        state
        | queue: :queue.in(project_id, state.queue),
          queued: MapSet.put(state.queued, project_id)
      }
    end
  end

  defp running?(%{running: %{project_id: project_id}}, project_id), do: true
  defp running?(_state, _project_id), do: false

  defp start_next(%{running: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, project_id}, queue} ->
        state = %{state | queue: queue, queued: MapSet.delete(state.queued, project_id)}
        runner = state.runner || default_runner()
        task = Task.Supervisor.async_nolink(TaskSupervisor, fn -> runner.(project_id) end)

        %{
          state
          | running: %{
              ref: task.ref,
              pid: task.pid,
              project_id: project_id,
              timer: arm_timeout(task.ref, state.timeout_ms)
            }
        }

      {:empty, _queue} ->
        state
    end
  end

  defp start_next(state), do: state

  defp arm_timeout(ref, timeout) when is_integer(timeout) and timeout > 0 do
    Process.send_after(self(), {:repack_timeout, ref}, timeout)
  end

  defp arm_timeout(_ref, _timeout), do: nil

  defp disarm_timeout(nil), do: :ok
  defp disarm_timeout(timer), do: Process.cancel_timer(timer)

  defp default_runner do
    Application.get_env(:cadence_server, :repack_runner, &Storage.run_if_needed/1)
  end

  # `:busy` means another process is already repacking the project: not a
  # failure, but also not evidence of success, so an existing cooldown stays.
  defp finish(state, project_id, result) do
    case result do
      {:error, :busy} ->
        state

      {:error, :disabled} ->
        %{state | failed_at: Map.delete(state.failed_at, project_id)}

      # A killed run is the one failure with a distinct, useful log line.
      {:error, :timeout} ->
        Logger.warning(
          "repack run timed out project=#{project_id} timeout_ms=#{state.timeout_ms}"
        )

        %{state | failed_at: Map.put(state.failed_at, project_id, now())}

      {:error, reason} ->
        Logger.warning(
          "repack failed project=#{project_id} reason=#{inspect(Storage.shape(reason))}"
        )

        %{state | failed_at: Map.put(state.failed_at, project_id, now())}

      _ok_or_skipped ->
        %{state | failed_at: Map.delete(state.failed_at, project_id)}
    end
  end

  defp cooling_down?(state, project_id) do
    case Map.get(state.failed_at, project_id) do
      nil -> false
      at -> now() - at < state.cooldown_ms
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  ## Backstop

  defp schedule_backstop(%{interval_ms: interval_ms} = state)
       when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :backstop, interval_ms)
    state
  end

  defp schedule_backstop(state), do: state

  defp list_projects(projects) do
    {:ok, projects.()}
  rescue
    error ->
      Logger.warning("repack backstop project list failed class=#{inspect(error.__struct__)}")
      {:error, :crashed}
  catch
    kind, _reason ->
      Logger.warning("repack backstop project list failed class=#{inspect(kind)}")
      {:error, :crashed}
  end

  defp crash_class({exception, _stacktrace}) when is_exception(exception),
    do: exception.__struct__

  defp crash_class(reason) when is_atom(reason), do: reason
  defp crash_class(_reason), do: :error
end
