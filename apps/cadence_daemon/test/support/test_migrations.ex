defmodule Cadence.Daemon.TestMigrations do
  @moduledoc """
  Runs every daemon migration against the test repo.

  Shared by `test/test_helper.exs` and tests that restart the application
  against a fresh SQLite database.
  """

  @spec migrate!() :: :ok
  def migrate! do
    # A restarted app gets a fresh `:memory:` database, so the migrations run
    # again in the same VM and their modules are redefined. That is expected
    # here; suppress the conflict warning so test output stays readable.
    previous = Code.compiler_options(ignore_module_conflict: true)

    try do
      Ecto.Migrator.run(
        Cadence.Daemon.Repo,
        Application.app_dir(:cadence_daemon, "priv/repo/migrations"),
        :up,
        all: true
      )
    after
      Code.compiler_options(previous)
    end

    :ok
  end
end
