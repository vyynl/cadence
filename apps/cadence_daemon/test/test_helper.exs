ExUnit.start()

{:ok, _} = Application.ensure_all_started(:cadence_daemon)

Cadence.Daemon.TestMigrations.migrate!()
