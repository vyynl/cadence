defmodule Cadence.Daemon.BootGuardTest do
  @moduledoc """
  Regression: a fresh state dir with sync configured must boot the daemon.

  Before the guard, `Cadence.Daemon.Application.maybe_start_sync/0` called
  `SyncLedger.rehydrate/0` against an unmigrated SQLite database; the
  "no such table: sync_state" error terminated the ledger and made the
  application start return a `:bad_return`. The other rehydrates already
  warned and skipped. The boot also reaches the first `SyncWorker.wake_all/0`,
  which must tolerate the missing `project_locations` table the same way.

  The test repo is SQLite `:memory:`, so stopping the application closes the
  only connection and discards the migrated schema. Restarting is exactly the
  "fresh state dir" boot from spec §12.2.
  """

  use ExUnit.Case, async: false

  alias Cadence.Daemon.TestMigrations

  @sync_keys [:server_url, :auth_token, :sync_enabled, :sync_channel_enabled]

  setup do
    previous = Map.new(@sync_keys, &{&1, Application.fetch_env(:cadence_daemon, &1)})

    # Registered before the stop so a failed boot (or an assertion) still
    # leaves a migrated repo behind for the rest of the suite. Sync config is
    # cleared first so this restart cannot re-enter the boot guard; a successful
    # boot leaves the app running against the empty database, so it only needs
    # the migrations.
    on_exit(fn ->
      restore(previous)

      case Application.ensure_all_started(:cadence_daemon) do
        {:ok, _} ->
          TestMigrations.migrate!()

        {:error, reason} ->
          raise "could not restart cadence_daemon after the boot test: #{inspect(reason)}"
      end
    end)

    :ok
  end

  test "sync-configured boot survives an unmigrated database" do
    :ok = Application.stop(:cadence_daemon)

    Application.put_env(:cadence_daemon, :server_url, "http://127.0.0.1:1")
    Application.put_env(:cadence_daemon, :auth_token, "boot-guard-test-token")
    Application.put_env(:cadence_daemon, :sync_enabled, true)
    Application.put_env(:cadence_daemon, :sync_channel_enabled, false)

    assert {:ok, _apps} = Application.ensure_all_started(:cadence_daemon)
    assert is_pid(Process.whereis(Cadence.Daemon.Repo))
    assert is_pid(Process.whereis(Cadence.Daemon.SyncLedger))
    assert is_pid(Process.whereis(Cadence.Daemon.SyncWorker))

    # The notification socket reads the server user id on connect; before the
    # guard this crashed the ledger (and the socket) on an unmigrated database.
    assert Cadence.Daemon.SyncLedger.server_user_id() == nil

    # `wake_all/0` is a cast, so the boot itself cannot prove the worker
    # survived. Send one more from this process and drain it: `:sys.get_state/1`
    # is ordered after our cast, and a crash would replace the registered pid.
    worker = Process.whereis(Cadence.Daemon.SyncWorker)
    Cadence.Daemon.SyncWorker.wake_all()
    assert :sys.get_state(Cadence.Daemon.SyncWorker)
    assert Process.whereis(Cadence.Daemon.SyncWorker) == worker
  end

  defp restore(previous) do
    Enum.each(previous, fn
      {key, {:ok, value}} -> Application.put_env(:cadence_daemon, key, value)
      {key, :error} -> Application.delete_env(:cadence_daemon, key)
    end)
  end
end
