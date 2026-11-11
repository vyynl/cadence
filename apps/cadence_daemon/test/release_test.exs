defmodule Cadence.Daemon.ReleaseTest do
  use ExUnit.Case, async: true

  alias Cadence.Daemon.{Dirs, Release, Repo}

  test "repos/0 returns the daemon repo" do
    assert Release.repos() == [Repo]
  end

  test "migrations_path/1 resolves the app's priv/repo/migrations" do
    assert Release.migrations_path(Repo) ==
             Application.app_dir(:cadence_daemon, "priv/repo/migrations")
  end

  describe "Dirs.ensure_repo_dir!/1" do
    setup do
      root = Path.join(System.tmp_dir!(), "cadence_dirs_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(root) end)
      %{root: root}
    end

    test "creates the database parent directory owner-only", %{root: root} do
      state = Path.join(root, "state")
      database = Path.join(state, "cadence.db")

      assert :ok = Dirs.ensure_repo_dir!(database)
      assert File.dir?(state)
      assert Bitwise.band(File.stat!(state).mode, 0o777) == 0o700

      # Idempotent on every boot/migrate.
      assert :ok = Dirs.ensure_repo_dir!(database)
    end

    test "ignores :memory:, an unset database, and a bare relative filename" do
      assert :ok = Dirs.ensure_repo_dir!(":memory:")
      assert :ok = Dirs.ensure_repo_dir!(nil)

      # `Path.dirname("cadence.db")` is "." — must never chmod the CWD.
      cwd = File.cwd!()
      before = File.stat!(cwd).mode
      assert :ok = Dirs.ensure_repo_dir!("cadence.db")
      assert File.stat!(cwd).mode == before
    end
  end
end
