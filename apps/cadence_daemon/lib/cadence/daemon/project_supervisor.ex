defmodule Cadence.Daemon.ProjectSupervisor do
  @moduledoc """
  Supervises a project's `{CommitQueue, Watcher}` pair as a single unit.

  `ProjectRegistry` starts one of these per project. Using `:rest_for_one`
  means a crash in the commit queue also restarts the watcher that feeds it,
  while a watcher crash restarts only the watcher. This avoids the previous
  layout where starting the queue and watcher as separate `DynamicSupervisor`
  children could orphan the queue if the watcher failed to boot.
  """

  use Supervisor

  alias Cadence.Daemon.{CommitQueue, Watcher}

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    work_dir = Keyword.fetch!(opts, :work_dir)
    git_dir = Keyword.fetch!(opts, :git_dir)

    queue_name = {:via, Registry, {Cadence.Daemon.Queues, project_id}}

    watcher_opts =
      [dir: work_dir, commit_queue: queue_name]
      |> maybe_put(:debounce_ms, opts[:debounce_ms])
      |> maybe_put(:backend, opts[:backend])
      |> maybe_put(:interval, opts[:interval])

    children = [
      {CommitQueue,
       [project_id: project_id, work_dir: work_dir, git_dir: git_dir, name: queue_name]},
      {Watcher, watcher_opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
