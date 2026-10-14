defmodule Cadence.Daemon.ProjectRegistry do
  @moduledoc """
  Supervises one `{CommitQueue, Watcher}` pair per registered project.

  The commit queue is registered under `Cadence.Daemon.Queues` keyed by
  `project_id` so callers (e.g. the API) can reach it via `lookup_queue/1`.
  """

  use DynamicSupervisor

  alias Cadence.Daemon.{CommitQueue, Watcher}

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Starts a commit queue and watcher for a project. Returns
  `{:ok, %{queue: pid, watcher: pid}}`.
  """
  def start_project(opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    work_dir = Keyword.fetch!(opts, :work_dir)
    git_dir = Keyword.fetch!(opts, :git_dir)

    queue_name = {:via, Registry, {Cadence.Daemon.Queues, project_id}}

    {:ok, queue} =
      DynamicSupervisor.start_child(
        __MODULE__,
        {CommitQueue,
         [project_id: project_id, work_dir: work_dir, git_dir: git_dir, name: queue_name]}
      )

    watcher_opts =
      [dir: work_dir, commit_queue: queue]
      |> maybe_put(:debounce_ms, opts[:debounce_ms])
      |> maybe_put(:backend, opts[:backend])

    {:ok, watcher} = DynamicSupervisor.start_child(__MODULE__, {Watcher, watcher_opts})

    {:ok, %{queue: queue, watcher: watcher}}
  end

  @doc "Returns the commit-queue pid for `project_id`, or `nil` if not registered."
  @spec lookup_queue(Ecto.UUID.t()) :: pid() | nil
  def lookup_queue(project_id) do
    GenServer.whereis({:via, Registry, {Cadence.Daemon.Queues, project_id}})
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
