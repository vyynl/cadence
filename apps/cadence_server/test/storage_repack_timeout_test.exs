defmodule Cadence.Server.StorageRepackTimeoutTest do
  @moduledoc """
  Proves the timeout design's safety assumption: a client killed while it holds
  `Storage.run/2`'s transaction-scoped advisory lock releases the lock and its
  pooled connection.

  Deliberately unboxed (`:auto`): a brutal kill on a sandboxed (shared or
  checked-out) connection invalidates the owner's checkout, so the sandbox
  cannot model a production pool of independent connections. The test creates no
  rows and no fixtures — only a temporary store and an advisory lock — and
  restores `:manual` when the module finishes.
  """

  use ExUnit.Case, async: false

  import Cadence.Server.TestHelpers, only: [eventually: 1, eventually: 2]

  alias Cadence.Server.{ProjectGit, Repo, Storage}
  alias Cadence.Server.Storage.Repacker
  alias Cadence.Shared.GitStore

  setup_all do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual) end)
    :ok
  end

  setup do
    project_id = Ecto.UUID.generate()
    on_exit(fn -> File.rm_rf!(ProjectGit.path(project_id)) end)

    store = ProjectGit.init(project_id)
    GitStore.write_blob(store, "one\n")

    %{project_id: project_id}
  end

  test "a killed run releases its project lock", %{project_id: project_id} do
    parent = self()

    task =
      Task.Supervisor.async_nolink(Cadence.Server.Storage.TaskSupervisor, fn ->
        Storage.run(project_id,
          packer: fn _store, _objects ->
            send(parent, :packing)

            receive do
              :hold -> :ok
            end

            {:error, :aborted}
          end
        )
      end)

    # The packer only runs inside `with_lock`, so reaching it proves the lock
    # is held; a second run on another pooled connection must see it.
    assert_receive :packing, 1_000
    assert Storage.run(project_id) == {:error, :busy}

    pid = task.pid
    ref = task.ref
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

    # The rollback releases the transaction-scoped lock and returns the pooled
    # connection, so the next run completes instead of staying busy forever.
    # `Storage.run/1` is idempotent; retry until it stops reporting `:busy`,
    # with an explicit bound for a slow host.
    assert eventually(fn -> Storage.run(project_id) != {:error, :busy} end, 10_000)
  end

  test "the worker kills a hung run and the next project proceeds" do
    first = Ecto.UUID.generate()
    second = Ecto.UUID.generate()

    on_exit(fn ->
      Enum.each([first, second], &File.rm_rf!(ProjectGit.path(&1)))
    end)

    Enum.each([first, second], fn id ->
      ProjectGit.init(id) |> GitStore.write_blob("one\n")
    end)

    parent = self()

    runner = fn id ->
      if id == first do
        Storage.run(id,
          packer: fn _store, _objects ->
            send(parent, {:packing, id})

            receive do
              :hold -> :ok
            end

            {:error, :aborted}
          end
        )
      else
        send(parent, {:done, id, Storage.run(id)})
      end
    end

    start_supervised!({
      Repacker,
      # Generous enough that the second project's real pack write (fsyncs,
      # verify reads) completes even on a slow host.
      name: :repack_timeout_test,
      interval_ms: 0,
      cooldown_ms: 60_000,
      timeout_ms: 300,
      runner: runner
    })

    Repacker.schedule(first, server: :repack_timeout_test)
    Repacker.schedule(second, server: :repack_timeout_test)

    assert_receive {:packing, ^first}, 1_000
    assert_receive {:done, ^second, {:ok, %{packed_objects: 1}}}, 2_000

    # The worker's kill released the first project's lock, so it can run again.
    # `Storage.run/1` is idempotent; retry until it stops reporting `:busy`,
    # with an explicit bound for a slow host.
    assert eventually(fn -> Storage.run(first) != {:error, :busy} end, 10_000)
  end
end
