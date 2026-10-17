ExUnit.start()

repo_config = Cadence.Server.Repo.config()

case Ecto.Adapters.Postgres.storage_up(repo_config) do
  :ok -> :ok
  {:error, :already_up} -> :ok
  {:error, reason} -> raise "could not create test database: #{inspect(reason)}"
end

{:ok, _} = Application.ensure_all_started(:cadence_server)

Ecto.Migrator.run(
  Cadence.Server.Repo,
  Application.app_dir(:cadence_server, "priv/repo/migrations"),
  :up,
  all: true
)

Ecto.Adapters.SQL.Sandbox.mode(Cadence.Server.Repo, :manual)
