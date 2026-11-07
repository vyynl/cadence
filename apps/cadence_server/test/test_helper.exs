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

git_store_path = Application.get_env(:cadence_server, :git_store_path)

if git_store_path do
  System.at_exit(fn _ -> File.rm_rf!(git_store_path) end)
end

for key <- [:actions_volume_path, :artifact_path] do
  case Application.get_env(:cadence_server, key) do
    path when is_binary(path) -> System.at_exit(fn _ -> File.rm_rf!(path) end)
    _other -> :ok
  end
end
