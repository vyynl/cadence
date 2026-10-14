defmodule Cadence.Daemon.ProjectRegistry do
  @moduledoc """
  Supervises one `Cadence.Daemon.ProjectSupervisor` per registered project.

  Each project supervisor owns its `{CommitQueue, Watcher}` pair. The commit
  queue is registered under `Cadence.Daemon.Queues` keyed by `project_id` so
  callers (e.g. the API) can reach it via `lookup_queue/1`.
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
    DynamicSupervisor.start_child(__MODULE__, {ProjectSupervisor, opts})
  end

  @doc "Returns the commit-queue pid for `project_id`, or `nil` if not registered."
  @spec lookup_queue(Ecto.UUID.t()) :: pid() | nil
  def lookup_queue(project_id) do
    GenServer.whereis({:via, Registry, {Cadence.Daemon.Queues, project_id}})
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)
end
