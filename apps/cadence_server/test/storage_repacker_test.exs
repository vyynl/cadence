defmodule Cadence.Server.StorageRepackerTest do
  use ExUnit.Case, async: false

  alias Cadence.Server.Storage.Repacker
  alias Cadence.Server.{ProjectGit, Repo, Storage}
  alias Cadence.Shared.GitStore

  import Cadence.ServerFixtures, only: [project: 1]

  @author %{name: "Storage Test", email: "storage@example.com"}

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    project = project(Ecto.UUID.generate())
    on_exit(fn -> File.rm_rf!(ProjectGit.path(project.id)) end)

    %{project: project, store: ProjectGit.init(project.id)}
  end

  describe "threshold" do
    test "below the threshold nothing is written", %{project: project, store: store} do
      put_env(:repack_min_objects, 100)
      put_env(:repack_min_bytes, 1_000_000)
      write_blobs(store, 3)

      assert Storage.run_if_needed(project.id) == :below_threshold
      assert GitStore.packs(store) == []
      assert length(GitStore.loose_objects(store)) == 3
    end

    test "the object count alone can trigger a run", %{project: project, store: store} do
      put_env(:repack_min_objects, 2)
      put_env(:repack_min_bytes, 1_000_000)
      write_blobs(store, 3)

      assert {:ok, %{packed_objects: 3}} = Storage.run_if_needed(project.id)
    end

    test "the byte total alone can trigger a run", %{project: project, store: store} do
      put_env(:repack_min_objects, 1_000_000)
      put_env(:repack_min_bytes, 1)
      write_blobs(store, 1)

      assert {:ok, %{packed_objects: 1}} = Storage.run_if_needed(project.id)
    end
  end

  describe "run/2" do
    test "packs loose objects and leaves every loose copy in place", %{
      project: project,
      store: store
    } do
      {shas, contents} = write_blobs(store, 3)

      assert {:ok, summary} = Storage.run(project.id)

      assert summary.packed_objects == 3
      assert summary.swept_loose == 0
      assert length(summary.packs) == 1
      assert length(GitStore.packs(store)) == 1
      assert length(GitStore.loose_objects(store)) == 3

      Enum.zip(shas, contents)
      |> Enum.each(fn {sha, content} -> assert GitStore.read_blob(store, sha) == content end)
    end

    test "a later run sweeps verified loose copies and every read path still works", %{
      project: project,
      store: store
    } do
      put_env(:repack_min_objects, 1)
      put_env(:repack_min_bytes, 1)

      blob = GitStore.write_blob(store, "hello\n")

      tree =
        GitStore.write_tree(store, [
          %{name: "a.txt", mode: "100644", type: :blob, ref: blob}
        ])

      commit = GitStore.write_commit(store, tree, [], @author, "root")

      assert {:ok, first} = Storage.run_if_needed(project.id)
      assert first.swept_loose == 0
      assert length(GitStore.loose_objects(store)) == 3

      # Loose copies still count toward the threshold, so the next check is
      # exactly the deferred sweep.
      assert {:ok, second} = Storage.run_if_needed(project.id)
      assert second.swept_loose == 3
      assert second.packed_objects == 0
      assert GitStore.loose_objects(store) == []

      assert {:ok, objects} = GitStore.objects_from(store, commit)
      assert length(objects) == 3
      assert %{tree: ^tree} = GitStore.read_commit(store, commit)
      assert [%{name: "a.txt"}] = GitStore.read_tree(store, tree)
      assert {:ok, "hello\n"} = GitStore.read_path(store, commit, "a.txt")
      assert GitStore.has_object?(store, commit)
    end

    test "after the sweep a run is idempotent", %{project: project, store: store} do
      write_blobs(store, 2)
      assert {:ok, _first} = Storage.run(project.id)
      assert {:ok, _second} = Storage.run(project.id)

      assert {:ok, third} = Storage.run(project.id)
      assert third.packed_objects == 0
      assert third.swept_loose == 0
      assert third.swept_tmp == 0
      assert length(GitStore.packs(store)) == 1
    end

    test "a run after a sweep packs only new loose objects", %{project: project, store: store} do
      {[old_sha], [old_content]} = write_blobs(store, 1)

      assert {:ok, first} = Storage.run(project.id)
      assert first.packed_objects == 1
      assert {:ok, swept} = Storage.run(project.id)
      assert swept.swept_loose == 1
      assert GitStore.loose_objects(store) == []

      [old_pack] = GitStore.packs(store)
      old_pack_bytes = File.read!(old_pack.pack_path)
      old_idx_bytes = File.read!(old_pack.idx_path)

      {new_shas, new_contents} = write_blobs(store, 3, 64)

      assert {:ok, third} = Storage.run(project.id)
      assert third.packed_objects == 3
      assert third.swept_loose == 0
      assert length(third.packs) == 1
      assert length(GitStore.packs(store)) == 2

      # The already-packed store is untouched: only the new blobs form a pack.
      assert File.read!(old_pack.pack_path) == old_pack_bytes
      assert File.read!(old_pack.idx_path) == old_idx_bytes
      assert length(GitStore.loose_objects(store)) == 3

      assert {:ok, fourth} = Storage.run(project.id)
      assert fourth.swept_loose == 3
      assert fourth.packed_objects == 0
      assert GitStore.loose_objects(store) == []
      assert length(GitStore.packs(store)) == 2

      assert GitStore.read_blob(store, old_sha) == old_content

      Enum.zip(new_shas, new_contents)
      |> Enum.each(fn {sha, content} -> assert GitStore.read_blob(store, sha) == content end)
    end

    test "stale temporary pack pairs and orphan packs are removed", %{
      project: project,
      store: store
    } do
      dir = Path.join([store.home_dir, "objects", "pack"])
      File.mkdir_p!(dir)

      tmp = ["tmp-1-pack-abc.pack.tmp", "tmp-2-pack-def.idx.tmp"]
      orphan_pack = "pack-" <> String.duplicate("a", 40) <> ".pack"
      orphan_idx = "pack-" <> String.duplicate("b", 40) <> ".idx"
      fresh_orphan = "pack-" <> String.duplicate("c", 40) <> ".pack"

      (tmp ++ [orphan_pack, orphan_idx, fresh_orphan])
      |> Enum.each(fn name -> File.write!(Path.join(dir, name), "junk") end)

      (tmp ++ [orphan_pack, orphan_idx])
      |> Enum.each(fn name -> File.touch!(Path.join(dir, name), {{2020, 1, 1}, {0, 0, 0}}) end)

      assert {:ok, summary} = Storage.run(project.id)
      assert summary.swept_tmp == 2
      assert summary.swept_orphans == 2
      assert summary.cleanup_failed == 0
      refute Enum.any?(tmp ++ [orphan_pack, orphan_idx], &File.exists?(Path.join(dir, &1)))

      # A rename in flight (no grace elapsed yet) is left alone.
      assert File.exists?(Path.join(dir, fresh_orphan))
    end

    test "an oversized set is split into several packs", %{project: project, store: store} do
      put_env(:repack_max_pack_bytes, 128)
      {shas, contents} = write_blobs(store, 5, 64)

      assert {:ok, summary} = Storage.run(project.id)
      assert summary.packed_objects == 5
      assert length(summary.packs) >= 2
      assert length(GitStore.packs(store)) == length(summary.packs)

      assert {:ok, _sweep} = Storage.run(project.id)
      assert GitStore.loose_objects(store) == []

      Enum.zip(shas, contents)
      |> Enum.each(fn {sha, content} -> assert GitStore.read_blob(store, sha) == content end)
    end

    test "an object larger than the cap becomes its own pack", %{project: project, store: store} do
      put_env(:repack_max_pack_bytes, 100)
      big_content = String.duplicate("b", 512)
      big = GitStore.write_blob(store, big_content)
      small1 = GitStore.write_blob(store, "one")
      small2 = GitStore.write_blob(store, "two")

      assert {:ok, summary} = Storage.run(project.id)
      assert summary.packed_objects == 3
      assert summary.packs |> Enum.map(& &1.objects) |> Enum.sort() == [1, 2]

      assert {:ok, _sweep} = Storage.run(project.id)
      assert GitStore.loose_objects(store) == []

      assert GitStore.read_blob(store, big) == big_content
      assert GitStore.read_blob(store, small1) == "one"
      assert GitStore.read_blob(store, small2) == "two"
    end

    test "a pack whose trailer no longer matches is not trusted for deletion", %{
      project: project,
      store: store
    } do
      {shas, contents} = write_blobs(store, 3)
      assert {:ok, _first} = Storage.run(project.id)

      pack = hd(GitStore.packs(store))
      File.write!(pack.pack_path, binary_part(File.read!(pack.pack_path), 0, 15))
      GitStore.invalidate_cache(store)

      assert {:ok, retry} = Storage.run(project.id)
      assert retry.swept_loose == 0
      assert length(GitStore.loose_objects(store)) == 3
      assert length(GitStore.packs(store)) == 1

      assert {:ok, swept} = Storage.run(project.id)
      assert swept.swept_loose == 3

      Enum.zip(shas, contents)
      |> Enum.each(fn {sha, content} -> assert GitStore.read_blob(store, sha) == content end)
    end

    test "a failed pack leaves loose copies and the store readable", %{
      project: project,
      store: store
    } do
      {[sha], _contents} = write_blobs(store, 1)

      assert {:error, {:pack_failed, :boom}} =
               Storage.run(project.id, packer: fn _store, _objects -> {:error, :boom} end)

      assert GitStore.packs(store) == []
      assert [%{sha: ^sha}] = GitStore.loose_objects(store)
      assert GitStore.read_blob(store, sha) != nil
    end

    test "unreadable loose objects are skipped and kept", %{project: project, store: store} do
      garbage_sha = String.duplicate("ab", 20)
      garbage_path = loose_path(store, garbage_sha)
      File.mkdir_p!(Path.dirname(garbage_path))
      File.write!(garbage_path, "not zlib")

      {[sha], _contents} = write_blobs(store, 1)

      assert {:ok, summary} = Storage.run(project.id)
      assert summary.skipped == 1
      assert summary.packed_objects == 1
      assert File.exists?(garbage_path)
      assert GitStore.read_blob(store, sha) != nil
    end

    test "a set with only unreadable loose objects is reported, not packed", %{
      project: project,
      store: store
    } do
      garbage_sha = String.duplicate("cd", 20)
      garbage_path = loose_path(store, garbage_sha)
      File.mkdir_p!(Path.dirname(garbage_path))
      File.write!(garbage_path, "not zlib")

      assert {:ok, summary} = Storage.run(project.id)
      assert summary.skipped == 1
      assert summary.packed_objects == 0
      assert summary.packs == []
      assert File.exists?(garbage_path)
    end

    test "a decodable loose file that hashes to a different SHA is skipped", %{
      project: project,
      store: store
    } do
      wrong_sha = String.duplicate("ef", 20)
      wrong_path = loose_path(store, wrong_sha)
      File.mkdir_p!(Path.dirname(wrong_path))
      File.write!(wrong_path, :zlib.compress("blob 5\0other"))

      assert {:ok, summary} = Storage.run(project.id)
      assert summary.skipped == 1
      assert summary.packed_objects == 0
      assert File.exists?(wrong_path)
    end

    test "a corrupt pack copy is never used to delete the loose object", %{
      project: project,
      store: store
    } do
      {[corrupt_sha | rest], contents} = write_blobs(store, 3)
      shas = [corrupt_sha | rest]
      assert {:ok, _first} = Storage.run(project.id)

      pack = hd(GitStore.packs(store))
      offset = Map.fetch!(pack.offsets, corrupt_sha)
      File.write!(pack.pack_path, corrupt_entry(File.read!(pack.pack_path), offset))
      GitStore.invalidate_cache(store)

      assert GitStore.verify_packed(store, corrupt_sha) == {:error, :corrupt}

      # The corrupted entry must not authorize deleting that loose copy; the
      # other two entries are intact and may be swept.
      assert {:ok, repair} = Storage.run(project.id)
      assert repair.swept_loose == 2
      assert repair.packed_objects == 1
      assert length(GitStore.packs(store)) == 2
      assert length(GitStore.loose_objects(store)) == 1

      # A repaired pack on a later run authorizes the deferred deletion.
      assert {:ok, swept} = Storage.run(project.id)
      assert swept.swept_loose == 1
      assert GitStore.loose_objects(store) == []

      Enum.zip(shas, contents)
      |> Enum.each(fn {sha, content} -> assert GitStore.read_blob(store, sha) == content end)
    end

    test "a held lock reports busy", %{project: project} do
      assert {:error, :busy} =
               Storage.run(project.id, lock: fn _project_id, _fun -> {:error, :busy} end)
    end

    test "the advisory lock is released between runs", %{project: project, store: store} do
      write_blobs(store, 1)

      assert {:ok, _first} = Storage.run(project.id)
      assert {:ok, _second} = Storage.run(project.id)
    end

    test "stats/1 reports loose and packed counts", %{project: project, store: store} do
      write_blobs(store, 3)
      assert %{loose_objects: 3, packed_objects: 0, pack_count: 0} = Storage.stats(project.id)

      assert {:ok, _first} = Storage.run(project.id)
      assert {:ok, _second} = Storage.run(project.id)

      assert %{loose_objects: 0, loose_bytes: 0, packed_objects: 3, pack_count: 1} =
               Storage.stats(project.id)
    end

    test "a disabled deployment performs no work", %{project: project} do
      put_env(:repack_enabled, false)

      assert Storage.run(project.id) == {:error, :disabled}
      assert Storage.run_if_needed(project.id) == :disabled
      assert Storage.maybe_repack(project.id) == :ok
    end
  end

  describe "Repacker" do
    test "the backstop runs every project and reschedules", %{project: project} do
      parent = self()
      runner = fn id -> send(parent, {:ran, id}) end

      start_supervised!(
        {Repacker,
         name: :test_repacker,
         interval_ms: 40,
         cooldown_ms: 1_000,
         projects: fn -> [project.id] end,
         runner: runner}
      )

      assert_receive {:ran, id}, 1_000
      assert id == project.id
      assert_receive {:ran, ^id}, 1_000
    end

    test "a project is queued once while a run is in flight", %{project: project} do
      parent = self()

      runner = fn id ->
        send(parent, {:ran, id})
        Process.sleep(100)
      end

      start_supervised!(
        {Repacker, name: :test_repacker, interval_ms: 0, cooldown_ms: 1_000, runner: runner}
      )

      Repacker.schedule(project.id, server: :test_repacker)
      Repacker.schedule(project.id, server: :test_repacker)

      assert_receive {:ran, id}, 1_000
      assert id == project.id
      refute_receive {:ran, _}, 200
    end

    test "the backstop retries a failed project despite the push cooldown", %{
      project: project
    } do
      parent = self()

      runner = fn id ->
        send(parent, {:ran, id})
        {:error, :boom}
      end

      start_supervised!(
        {Repacker,
         name: :test_repacker,
         interval_ms: 40,
         cooldown_ms: 60_000,
         projects: fn -> [project.id] end,
         runner: runner}
      )

      Repacker.schedule(project.id, server: :test_repacker)
      assert_receive {:ran, id}, 1_000
      assert id == project.id

      # The 40 ms backstop ignores the 60 s push cooldown and retries.
      assert_receive {:ran, _id}, 1_000
    end

    test "a failed run suppresses push triggers for the cooldown", %{project: project} do
      parent = self()

      runner = fn id ->
        send(parent, {:ran, id})
        {:error, :boom}
      end

      start_supervised!(
        {Repacker, name: :test_repacker, interval_ms: 0, cooldown_ms: 60_000, runner: runner}
      )

      Repacker.schedule(project.id, server: :test_repacker)
      assert_receive {:ran, id}, 1_000
      assert id == project.id
      await_idle(:test_repacker)

      Repacker.schedule(project.id, server: :test_repacker)
      refute_receive {:ran, _}, 200
    end

    test "a busy project is not recorded as a failure", %{project: project} do
      parent = self()

      runner = fn id ->
        send(parent, {:ran, id})
        {:error, :busy}
      end

      start_supervised!(
        {Repacker, name: :test_repacker, interval_ms: 0, cooldown_ms: 60_000, runner: runner}
      )

      Repacker.schedule(project.id, server: :test_repacker)
      assert_receive {:ran, id}, 1_000
      assert id == project.id
      await_idle(:test_repacker)

      Repacker.schedule(project.id, server: :test_repacker)
      assert_receive {:ran, ^id}, 1_000
    end

    test "a crash is recorded as a failure", %{project: project} do
      parent = self()

      runner = fn id ->
        send(parent, {:ran, id})
        raise "boom"
      end

      start_supervised!(
        {Repacker, name: :test_repacker, interval_ms: 0, cooldown_ms: 60_000, runner: runner}
      )

      Repacker.schedule(project.id, server: :test_repacker)
      assert_receive {:ran, id}, 1_000
      assert id == project.id
      await_idle(:test_repacker)

      Repacker.schedule(project.id, server: :test_repacker)
      refute_receive {:ran, _}, 200
    end
  end

  defp write_blobs(store, count, size \\ 32) do
    1..count
    |> Enum.map(fn index ->
      content = "object #{index} " <> String.duplicate("x", size)
      {GitStore.write_blob(store, content), content}
    end)
    |> Enum.unzip()
  end

  defp loose_path(store, sha) do
    <<dir::binary-size(2)>> <> rest = sha
    Path.join([store.home_dir, "objects", dir, rest])
  end

  # Zero bytes inside one entry while keeping the pack size and trailer intact,
  # so the index is still discovered and that entry's read must fail.
  defp corrupt_entry(bin, offset) do
    size = byte_size(bin)
    take = min(16, max(size - offset, 0))
    prefix = binary_part(bin, 0, offset)
    rest = binary_part(bin, offset + take, size - offset - take)
    prefix <> :binary.copy(<<0>>, take) <> rest
  end

  defp await_idle(name) do
    Enum.reduce_while(1..100, :ok, fn _attempt, _acc ->
      case :sys.get_state(name) do
        %{running: nil} ->
          {:halt, :ok}

        _state ->
          Process.sleep(10)
          {:cont, :ok}
      end
    end)
  end

  defp put_env(key, value) do
    previous = Application.get_env(:cadence_server, key)
    Application.put_env(:cadence_server, key, value)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:cadence_server, key)
      else
        Application.put_env(:cadence_server, key, previous)
      end
    end)
  end
end
