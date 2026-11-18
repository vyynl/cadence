defmodule Cadence.Daemon.Release do
  @moduledoc """
  One-shot release tasks for the daemon artifact (spec §12.2, §12.8).

  The daemon release is installed per machine and started with
  `bin/cadence_daemon start`. Migrations are **not** run from the release boot:
  a fresh state directory is migrated once with this module, and re-running it
  after an upgrade is the supported path.

      bin/cadence_daemon eval "Cadence.Daemon.Release.migrate()"

  Booting a daemon before the database is migrated is safe (rehydration logs a
  "skipped before migrations" warning and idles), but nothing syncs until the
  migration runs and the daemon restarts.

  `register/3` is the release equivalent of `mix cad.register`: it talks to an
  already-running daemon over its Unix socket, so it cannot bootstrap the first
  daemon start on its own. `eval` does not print a return value, so wrap the
  call to see the registered project:

      bin/cadence_daemon eval 'IO.inspect(Cadence.Daemon.Release.register("My Project", "my-project", "/home/you/code/my-project"))'
  """

  @app :cadence_daemon

  @doc """
  Applies every pending migration for the repos configured under
  `:cadence_daemon, :ecto_repos`.

  Safe to run repeatedly: `Ecto.Migrator` skips versions that are already
  recorded in `schema_migrations`. The database's parent directory is created
  owner-only first, so a fresh `CAD_STATE_DIR` needs no manual setup.
  """
  @spec migrate() :: :ok
  def migrate do
    load_app()

    Enum.each(repos(), fn repo ->
      ensure_repo_dir!(repo)

      {:ok, _repo, _started_apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end)
  end

  @doc "The repos this application migrates."
  @spec repos() :: [module()]
  def repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  @doc "The migration directory `Ecto` uses for `repo`."
  @spec migrations_path(module()) :: String.t()
  def migrations_path(repo) do
    Ecto.Migrator.migrations_path(repo)
  end

  @doc """
  Verifies that the configured server accepts the token.

  `setup` in the daemon image calls this so a wrong URL, a reject 401, or a
  missing network is reported while the operator still has the prompt in front
  of them, instead of failing silently on the first sync pass. Reasons:

    * `:not_configured` — no `CAD_SERVER_URL` or `CAD_AUTH_TOKEN`
    * `:unauthorized` — the server answered 401
    * `:certificate` — the TLS chain is not trusted (`CAD_SYNC_CA_FILE`)
    * `:unreachable` — DNS, connect, or timeout failure
    * `{:http, status}` — any other non-success response
    * `:unknown` — anything else; the caller prints the raw reason
  """
  @spec check_connection() ::
          :ok
          | {:error,
             :not_configured
             | :unauthorized
             | :certificate
             | :unreachable
             | :unknown
             | {:http, pos_integer()}}
  def check_connection do
    if Cadence.Daemon.SyncClient.configured?() do
      Application.ensure_all_started(:req)

      case Cadence.Daemon.SyncClient.me() do
        {:ok, _user_id} -> :ok
        {:error, reason} -> {:error, connection_error(reason)}
      end
    else
      {:error, :not_configured}
    end
  end

  defp connection_error({:http, 401, _body}), do: :unauthorized
  defp connection_error({:http, status, _body}) when is_integer(status), do: {:http, status}
  defp connection_error(%{reason: reason}), do: transport_error(reason)
  defp connection_error(_other), do: :unknown

  defp transport_error(reason) do
    if certificate_error?(reason), do: :certificate, else: :unreachable
  end

  defp certificate_error?({:tls_alert, _alert}), do: true
  defp certificate_error?(:unknown_ca), do: true

  defp certificate_error?(reason) do
    reason
    |> inspect()
    |> String.contains?(["unknown_ca", "certificate", "tls_alert"])
  end

  @doc """
  Registers a project with a running daemon and returns the decoded response.

  Equivalent to `mix cad.register` and `POST /projects` on the daemon socket.
  Raises when the daemon is not running or rejects the project.
  """
  @spec register(String.t(), String.t(), Path.t(), Path.t()) :: map()
  def register(name, slug, work_dir, socket_path \\ Cadence.Daemon.API.socket_path()) do
    Cadence.Daemon.Client.expect!(
      "POST",
      "/projects",
      %{"name" => name, "slug" => slug, "work_dir" => work_dir},
      socket_path
    )
  end

  @doc """
  Imports a local Git repository through a running daemon and returns the
  completed job.

  Equivalent to `mix cad.import`; options are `:refs` (list), `:all_refs`,
  `:allow_shallow`, `:limit`, `:project_id`, `:name`, and `:slug`. Raises when
  the daemon rejects the source or the job fails.
  """
  @spec import(Path.t(), keyword()) :: map()
  def import(path, opts \\ []),
    do: __MODULE__.import(path, opts, Cadence.Daemon.API.socket_path())

  @spec import(Path.t(), keyword(), Path.t()) :: map()
  def import(path, opts, socket_path) when is_list(opts) do
    attrs = Cadence.Daemon.ImportClient.attrs(path, opts)

    with {:ok, job} <- Cadence.Daemon.ImportClient.start(attrs, socket_path),
         {:ok, final} <- Cadence.Daemon.ImportClient.wait(job["id"], socket_path) do
      case final do
        %{"status" => "completed"} ->
          final

        %{"status" => "failed"} ->
          raise "import #{job["id"]} failed: #{format_job_error(final)}"
      end
    else
      {:error, :timeout} -> raise "import did not finish in time"
      {:error, {status, message}} -> raise "import request failed (#{status}): #{message}"
    end
  end

  defp format_job_error(%{"error" => %{"code" => code, "message" => message}}),
    do: "#{code}: #{message}"

  defp format_job_error(job), do: inspect(job["error"])

  defp ensure_repo_dir!(repo) do
    Cadence.Daemon.Dirs.ensure_repo_dir!(repo.config()[:database])
  end

  defp load_app do
    # Returns {:error, {:already_loaded, _}} when the release boot script has
    # already loaded it, which is fine.
    Application.load(@app)
    :ok
  end
end
