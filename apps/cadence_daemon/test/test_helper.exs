ExUnit.start()

{:ok, _} = Application.ensure_all_started(:cadence_daemon)

Ecto.Migrator.run(
  Cadence.Daemon.Repo,
  Application.app_dir(:cadence_daemon, "priv/repo/migrations"),
  :up,
  all: true
)
