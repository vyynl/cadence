defmodule Cadence.Server.Release do
  @moduledoc """
  One-shot release tasks for the production server artifact (spec §12.7,
  §12.8).

  Migrations are deliberately **not** run from the container entrypoint. The
  reference compose stack runs this module as a one-shot `migrate` service and
  starts the endpoint only after it succeeds:

      docker compose -f docker-compose.prod.yml up -d --build

  The same command can be run by hand:

      bin/cadence eval "Cadence.Server.Release.migrate()"
  """

  @app :cadence_server

  @doc """
  Applies every pending migration for the repos configured under
  `:cadence_server, :ecto_repos`.

  Safe to run repeatedly: `Ecto.Migrator` skips versions that are already
  recorded in `schema_migrations`.
  """
  @spec migrate() :: :ok
  def migrate do
    load_app()

    Enum.each(repos(), fn repo ->
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

  defp load_app do
    # Returns {:error, {:already_loaded, _}} when the release boot script has
    # already loaded it, which is fine.
    Application.load(@app)
    :ok
  end
end
