defmodule Cadence.Daemon.Application do
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    ensure_repo_dir!()
    warn_insecure_tls()

    children =
      [
        Cadence.Daemon.Repo,
        Cadence.Daemon.LLMRateLimit,
        Cadence.Daemon.AgentWorker,
        Cadence.Daemon.DocAgentWorker,
        Cadence.Daemon.MessageQueue,
        Cadence.Daemon.DocQueue,
        Cadence.Daemon.SyncLedger,
        {Task.Supervisor, name: Cadence.Daemon.SyncTasks},
        {Registry, keys: :unique, name: Cadence.Daemon.Queues},
        Cadence.Daemon.ProjectRegistry,
        {Task.Supervisor, name: Cadence.Daemon.ImportTasks},
        Cadence.Daemon.Importer,
        Cadence.Daemon.SyncWorker,
        Cadence.Daemon.SyncSocket
      ] ++ api_children()

    opts = [strategy: :one_for_one, name: Cadence.Daemon.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    Cadence.Daemon.Projects.rehydrate()
    Cadence.Daemon.MessageQueue.rehydrate()
    Cadence.Daemon.DocQueue.rehydrate()
    maybe_start_sync()

    {:ok, pid}
  end

  # Sync boot work is skipped entirely when the daemon is offline/unconfigured;
  # this also keeps test boots safe before their migrations run.
  defp maybe_start_sync do
    if Cadence.Daemon.Env.sync_enabled?() and Cadence.Daemon.SyncClient.configured?() do
      Cadence.Daemon.SyncLedger.rehydrate()
      Cadence.Daemon.SyncWorker.wake_all()
    end
  end

  # Disabling verification sends the token over an unauthenticated channel, so
  # say so once at boot rather than leaving it to be discovered in review.
  defp warn_insecure_tls do
    unless Cadence.Daemon.Env.sync_verify_tls?() do
      Logger.warning(
        "CAD_SYNC_VERIFY_TLS=false: the server's certificate is not verified " <>
          "for sync or the notification socket"
      )
    end
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
  # (test) databases. `Cadence.Daemon.Release.migrate/0` performs the same step
  # before starting the repo against a fresh `CAD_STATE_DIR`.
  defp ensure_repo_dir! do
    case Application.fetch_env(:cadence_daemon, Cadence.Daemon.Repo) do
      {:ok, config} ->
        Cadence.Daemon.Dirs.ensure_repo_dir!(Keyword.get(config, :database))

      :error ->
        :ok
    end
  end
end
