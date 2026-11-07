defmodule Cadence.Server.Storage do
  @moduledoc """
  Server-side storage maintenance for a project's bare Git store (spec §13
  Phase 7b, §16).

  A run packs loose objects into Git pack v2 files (7a) and removes loose
  copies that a **previous** run already packed and verified. The two phases
  are deliberately separate:

  1. **Sweep** — for every loose object covered by a usable pack, re-read the
     object *through the pack* and re-hash it (`GitStore.verify_packed/2`).
     Only a verified entry authorizes unlinking the loose file, so a torn
     rename or a corrupt pack can never lose the only copy. Unlink failures are
     counted and logged, never treated as a successful sweep. Crash-left
     `tmp-*` pairs and final-named packs with no index (older than a short
     grace period) are also removed.
  2. **Pack** — every remaining loose object is read from its **loose file
     only** (`GitStore.read_loose_raw/2`, so a corrupt loose copy is skipped
     instead of being silently replaced by a pack payload) and written into new
     pack(s) in `CAD_REPACK_MAX_PACK_BYTES` batches. Only one batch is resident
     at a time, so the cap bounds peak memory as well as pack size. This phase
     never deletes: OTP cannot fsync a directory, so the rename is only known
     durable on a later run.

  A single run therefore leaves pack + loose side by side (at most one backstop
  interval of transient 2× disk). Nothing prunes unreachable objects or
  history (§15).

  Threshold counts **on-disk loose objects and bytes**, including copies that a
  pack already covers: that is the disk pressure, and counting them makes the
  next trigger the sweep that removes them.

  Runs are serialized per project by a transaction-scoped Postgres advisory
  lock, so a crashed run cannot leak a lock on a pooled connection and a second
  process (another server node, or `mix cadence.repack`) gets `{:error,
  :busy}` instead of racing. `Cadence.Server.Storage.Repacker` owns the queue,
  the push trigger, and the 6 h backstop; this module is the synchronous body
  and the manual entry point.
  """

  require Logger

  import Ecto.Query

  alias Cadence.Server.{ProjectGit, Repo}
  alias Cadence.Server.Storage.Repacker
  alias Cadence.Shared.GitStore
  alias Cadence.Shared.Project

  @pack_dir "objects/pack"

  # Two-int form so a project id never has to fit in an int4; `hashtext` is
  # evaluated by the database that holds the lock (multi-node safe).
  @try_lock_sql "SELECT pg_try_advisory_xact_lock(hashtext('cadence.repack'), hashtext($1))"

  # Approximate framing overhead per packed entry (header + base info). Only
  # used to bound a batch's input size, never for correctness.
  @entry_overhead 32

  # Crash debris and half-completed renames must be older than this before the
  # sweep removes them, so a writer whose advisory lock was lost mid-run is
  # never mistaken for garbage.
  @cleanup_grace_seconds 300

  @type stats :: %{
          loose_objects: non_neg_integer(),
          loose_bytes: non_neg_integer(),
          packed_objects: non_neg_integer(),
          pack_count: non_neg_integer()
        }

  @type summary :: %{
          project_id: String.t(),
          loose_before: non_neg_integer(),
          loose_bytes_before: non_neg_integer(),
          packs: [map()],
          packed_objects: non_neg_integer(),
          packed_bytes: non_neg_integer(),
          swept_tmp: non_neg_integer(),
          swept_orphans: non_neg_integer(),
          cleanup_failed: non_neg_integer(),
          swept_loose: non_neg_integer(),
          unlink_failed: non_neg_integer(),
          skipped: non_neg_integer(),
          duration_ms: non_neg_integer()
        }

  ## Configuration

  @doc "Whether background repacking is enabled (`CAD_REPACK_ENABLED`)."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:cadence_server, :repack_enabled, true) == true

  @doc "Loose object count that triggers a repack (`CAD_REPACK_MIN_OBJECTS`)."
  @spec min_objects() :: non_neg_integer()
  def min_objects, do: Application.get_env(:cadence_server, :repack_min_objects, 1_000)

  @doc "On-disk loose bytes that trigger a repack (`CAD_REPACK_MIN_BYTES`)."
  @spec min_bytes() :: non_neg_integer()
  def min_bytes, do: Application.get_env(:cadence_server, :repack_min_bytes, 67_108_864)

  @doc """
  Backstop interval in milliseconds (`CAD_REPACK_INTERVAL_MS`).

  Also used as the push-trigger failure cooldown. `0` disables both the
  periodic backstop and the cooldown (so a failing store is retried on every
  push).
  """
  @spec interval_ms() :: non_neg_integer()
  def interval_ms,
    do: max(Application.get_env(:cadence_server, :repack_interval_ms, 21_600_000), 0)

  @doc "Maximum input bytes for one pack batch (`CAD_REPACK_MAX_PACK_BYTES`)."
  @spec max_pack_bytes() :: pos_integer()
  def max_pack_bytes,
    do: max(Application.get_env(:cadence_server, :repack_max_pack_bytes, 67_108_864), 1)

  ## Read models

  @doc """
  Loose/packed object counts for a project's store.

  `loose_bytes` is the on-disk (compressed) size reported by
  `GitStore.loose_objects/1`, so it matches the threshold semantic.
  """
  @spec stats(String.t()) :: stats()
  def stats(project_id) when is_binary(project_id) do
    store = ProjectGit.open(project_id)
    loose = GitStore.loose_objects(store)
    packs = GitStore.packs(store)

    packed =
      packs
      |> Enum.flat_map(fn pack -> Map.keys(pack.offsets) end)
      |> Enum.uniq()
      |> length()

    %{
      loose_objects: length(loose),
      loose_bytes: Enum.sum(Enum.map(loose, & &1.size)),
      packed_objects: packed,
      pack_count: length(packs)
    }
  end

  @doc "Every project id (backstop sweep and `mix cadence.repack`)."
  @spec project_ids() :: [String.t()]
  def project_ids do
    Repo.all(from p in Project, select: p.id)
  end

  ## Entry points

  @doc """
  Ask the repacker to check a project after a successful push.

  Best-effort: a disabled deployment, a missing `Repacker`, or a scheduling
  failure is swallowed (a push must never fail because of storage
  maintenance).
  """
  @spec maybe_repack(String.t()) :: :ok
  def maybe_repack(project_id) when is_binary(project_id) do
    with true <- enabled?(),
         pid when is_pid(pid) <- Process.whereis(Repacker) do
      Repacker.schedule(project_id, server: pid)
    end

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  def maybe_repack(_project_id), do: :ok

  @doc """
  Run a repack only when the store is at or above the threshold.

  Returns `:below_threshold` when nothing is due, `:disabled` when repacking is
  off, otherwise the `run/2` result.
  """
  @spec run_if_needed(String.t()) ::
          :disabled | :below_threshold | {:ok, summary()} | {:error, term()}
  def run_if_needed(project_id) when is_binary(project_id) do
    if enabled?() do
      current = stats(project_id)

      if current.loose_objects >= min_objects() or current.loose_bytes >= min_bytes() do
        run(project_id)
      else
        :below_threshold
      end
    else
      :disabled
    end
  end

  @doc """
  Repack one project's store (unconditional; the manual/backstop path).

  Options:

    * `:packer` — `fn store, objects -> {:ok, info} | {:error, reason} end`,
      defaults to `GitStore.pack_objects/3` (test seam).
    * `:lock` — `fn project_id, fun -> result end`, defaults to the Postgres
      advisory lock (test seam).
    * `:max_pack_bytes` — batch input cap, defaults to `max_pack_bytes/0`.

  Returns `{:ok, summary()}`, `{:error, :disabled}`, `{:error, :busy}` when
  another run holds the project lock, or `{:error, reason}` (shape-only).
  """
  @spec run(String.t(), keyword()) :: {:ok, summary()} | {:error, term()}
  def run(project_id, opts \\ [])

  def run(project_id, opts) when is_binary(project_id) do
    if enabled?() do
      store = ProjectGit.open(project_id)
      lock = Keyword.get(opts, :lock, &with_lock/2)
      lock.(project_id, fn -> run_store(project_id, store, opts) end)
    else
      {:error, :disabled}
    end
  end

  def run(_project_id, _opts), do: {:error, :invalid_project}

  ## Run body

  defp run_store(project_id, store, opts) do
    started = System.monotonic_time(:millisecond)
    packer = Keyword.get(opts, :packer, &GitStore.pack_objects/2)
    max_bytes = max(Keyword.get(opts, :max_pack_bytes, max_pack_bytes()), 1)

    # Another node or a CLI run may have written a pack since this VM cached the
    # store; refresh once per run so the sweep can see every pack it should
    # trust (and nothing that no longer exists).
    GitStore.invalidate_cache(store)

    loose_before = GitStore.loose_objects(store)
    {swept_tmp, swept_orphans, cleanup_failed} = sweep_pack_dir(store)
    {swept_loose, unlink_failed, packable} = sweep_loose(store, loose_before)

    if cleanup_failed > 0 do
      Logger.warning("repack cleanup failed project=#{project_id} count=#{cleanup_failed}")
    end

    if unlink_failed > 0 do
      Logger.warning("repack unlink failed project=#{project_id} count=#{unlink_failed}")
    end

    case pack_loose(store, packable, max_bytes, packer) do
      {:ok, packs, packed_objects, packed_bytes, skipped} ->
        summary = %{
          project_id: project_id,
          loose_before: length(loose_before),
          loose_bytes_before: Enum.sum(Enum.map(loose_before, & &1.size)),
          packs: packs,
          packed_objects: packed_objects,
          packed_bytes: packed_bytes,
          swept_tmp: swept_tmp,
          swept_orphans: swept_orphans,
          cleanup_failed: cleanup_failed,
          swept_loose: swept_loose,
          unlink_failed: unlink_failed,
          skipped: skipped,
          duration_ms: System.monotonic_time(:millisecond) - started
        }

        Logger.info(
          "repack project=#{project_id} loose=#{summary.loose_before} " <>
            "packs=#{length(packs)} objects=#{packed_objects} bytes=#{packed_bytes} " <>
            "swept=#{swept_loose} unlink_failed=#{unlink_failed} " <>
            "tmp=#{swept_tmp} orphans=#{swept_orphans} cleanup_failed=#{cleanup_failed} " <>
            "skipped=#{skipped} ms=#{summary.duration_ms}"
        )

        {:ok, summary}

      {:error, reason} ->
        Logger.warning(
          "repack pack failed project=#{project_id} reason=#{inspect(shape(reason))}"
        )

        {:error, {:pack_failed, shape(reason)}}
    end
  end

  # A crash-left `.tmp` pair is invisible to pack discovery and can never be a
  # live write: the project lock is held for the whole run, and `pack_objects/3`
  # only writes under that lock. A final-named `.pack` without its `.idx` (or
  # vice versa) is a half-completed rename that no reader can discover. Both
  # get a grace period so a writer whose lock was lost (DB backend terminated
  # mid-run) is never mistaken for debris.
  defp sweep_pack_dir(store) do
    dir = Path.join(store.home_dir, @pack_dir)

    case File.ls(dir) do
      {:ok, names} ->
        present = MapSet.new(names)

        removable =
          Enum.filter(names, fn name ->
            (tmp_pack?(name) or orphan_pack?(name, present)) and stale?(Path.join(dir, name))
          end)

        removed = Enum.count(removable, fn name -> File.rm(Path.join(dir, name)) == :ok end)

        temp = Enum.count(removable, &tmp_pack?/1)
        orphans = length(removable) - temp

        {temp, orphans, length(removable) - removed}

      {:error, _reason} ->
        {0, 0, 0}
    end
  end

  defp tmp_pack?(name) do
    String.starts_with?(name, "tmp-") and
      (String.ends_with?(name, ".pack.tmp") or String.ends_with?(name, ".idx.tmp"))
  end

  defp orphan_pack?(name, present) do
    case Regex.run(~r/^(pack-[0-9a-f]{40}\.(?:pack|idx))$/, name) do
      [_, file] -> not MapSet.member?(present, sibling(file))
      _ -> false
    end
  end

  defp sibling(file) do
    base = Path.rootname(file)
    if String.ends_with?(file, ".pack"), do: base <> ".idx", else: base <> ".pack"
  end

  defp stale?(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> System.os_time(:second) - mtime >= @cleanup_grace_seconds
      {:error, _reason} -> false
    end
  end

  # Delete a loose copy only after its pack entry read back and re-hashed. A
  # SHA whose pack copies are unreadable stays loose and is re-packed (repair);
  # a covered SHA whose unlink fails is left for the next run and reported.
  defp sweep_loose(store, loose_objects) do
    Enum.reduce(loose_objects, {0, 0, []}, fn loose, {swept, failed, packable} ->
      case GitStore.verify_packed(store, loose.sha) do
        :ok ->
          case File.rm(loose.path) do
            :ok -> {swept + 1, failed, packable}
            {:error, _reason} -> {swept, failed + 1, packable}
          end

        {:error, _reason} ->
          {swept, failed, [loose | packable]}
      end
    end)
    |> then(fn {swept, failed, packable} -> {swept, failed, Enum.reverse(packable)} end)
  end

  # Pack in bounded batches: only one batch's payloads are resident at a time,
  # so `CAD_REPACK_MAX_PACK_BYTES` bounds peak memory as well as output size.
  # A single object larger than the cap becomes its own batch. Tail-recursive
  # with an accumulator so the stack depth is constant.
  defp pack_loose(store, loose_objects, max_bytes, packer) do
    pack_loose(store, loose_objects, max_bytes, packer, [], 0, 0, 0)
  end

  defp pack_loose(_store, [], _max_bytes, _packer, packs, count, bytes, skipped) do
    {:ok, Enum.reverse(packs), count, bytes, skipped}
  end

  defp pack_loose(store, loose_objects, max_bytes, packer, packs, count, bytes, skipped) do
    {objects, rest, skipped_now} = read_batch(store, loose_objects, max_bytes)
    skipped = skipped + skipped_now

    # Every remaining loose object was unreadable: report the skip and never
    # ask the packer to write an empty pack.
    if objects == [] do
      {:ok, Enum.reverse(packs), count, bytes, skipped}
    else
      case packer.(store, objects) do
        {:ok, info} ->
          pack_loose(
            store,
            rest,
            max_bytes,
            packer,
            [info | packs],
            count + info.objects,
            bytes + info.bytes,
            skipped
          )

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp read_batch(store, loose_objects, max_bytes) do
    read_batch(store, loose_objects, max_bytes, [], 0, 0)
  end

  defp read_batch(_store, [], _max_bytes, objects, _size, skipped),
    do: {Enum.reverse(objects), [], skipped}

  defp read_batch(store, [loose | rest], max_bytes, objects, size, skipped) do
    # Read the loose file only: a corrupt loose object must be skipped, not
    # silently replaced by a (possibly corrupt) pack payload.
    case GitStore.read_loose_raw(store, loose.sha) do
      {:ok, {type, data}} ->
        object_size = byte_size(data) + @entry_overhead

        if objects != [] and size + object_size > max_bytes do
          {Enum.reverse(objects), [loose | rest], skipped}
        else
          object = %{sha: loose.sha, type: type, data: data}
          read_batch(store, rest, max_bytes, [object | objects], size + object_size, skipped)
        end

      {:error, _reason} ->
        read_batch(store, rest, max_bytes, objects, size, skipped + 1)
    end
  end

  ## Lock

  # Transaction-scoped so a killed run cannot leak a session lock on a pooled
  # connection. A raised run is contained inside the transaction and reported
  # as a shape-only error; the lock still releases on commit/rollback.
  defp with_lock(project_id, fun) do
    result =
      Repo.transaction(fn ->
        case Repo.query!(@try_lock_sql, [project_id]) do
          %{rows: [[true]]} -> {:ran, safe_run(fun)}
          _busy -> :busy
        end
      end)

    case result do
      {:ok, :busy} -> {:error, :busy}
      {:ok, {:ran, result}} -> result
      {:error, reason} -> {:error, {:lock_failed, shape(reason)}}
    end
  rescue
    error ->
      Logger.warning(
        "repack lock failed project=#{project_id} class=#{inspect(error.__struct__)}"
      )

      {:error, :lock_failed}
  end

  defp safe_run(fun) do
    fun.()
  rescue
    error ->
      Logger.warning("repack run crashed class=#{inspect(error.__struct__)}")
      {:error, :crashed}
  catch
    kind, _reason ->
      Logger.warning("repack run threw class=#{inspect(kind)}")
      {:error, :crashed}
  end

  # Never log or return object content: reasons are reduced to their tag.
  # Public so `Storage.Repacker` uses the same reduction.
  @doc false
  def shape(reason) when is_atom(reason), do: reason
  def shape({tag, _detail}) when is_atom(tag), do: tag
  def shape({tag, _detail, _extra}) when is_atom(tag), do: tag
  def shape(_reason), do: :error
end
