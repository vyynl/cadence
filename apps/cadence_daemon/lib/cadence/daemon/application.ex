defmodule Cadence.Daemon.Application do
  use Application

  @impl true
  def start(_type, _args) do
    ensure_repo_dir!()

    children =
      [
        Cadence.Daemon.Repo,
        Cadence.Daemon.LLMRateLimit,
        Cadence.Daemon.AgentWorker,
        Cadence.Daemon.MessageQueue,
        {Registry, keys: :unique, name: Cadence.Daemon.Queues},
        Cadence.Daemon.ProjectRegistry
      ] ++ api_children()

    opts = [strategy: :one_for_one, name: Cadence.Daemon.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    Cadence.Daemon.Projects.rehydrate()
    Cadence.Daemon.MessageQueue.rehydrate()

    {:ok, pid}
  end

  # The Unix-socket API is disabled in tests so booting the app doesn't bind the
  # real user socket; API integration tests start it explicitly with a temp path.
  defp api_children do
    if Application.get_env(:cadence_daemon, :start_api, true) do
      [Cadence.Daemon.API]
    else
      []
    end
  end

  # The SQLite database (and its WAL/SHM siblings) live inside a 0700
  # directory so only the owning user can reach them. Skipped for `:memory:`
  # (test) databases.
  defp ensure_repo_dir! do
    case Application.fetch_env(:cadence_daemon, Cadence.Daemon.Repo) do
      {:ok, config} ->
        case Keyword.get(config, :database) do
          path when is_binary(path) ->
            path |> Path.dirname() |> Cadence.Daemon.Dirs.ensure!()

          _ ->
            :ok
        end

      :error ->
        :ok
    end
  end
end
