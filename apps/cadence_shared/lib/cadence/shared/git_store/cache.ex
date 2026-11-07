defmodule Cadence.Shared.GitStore.Cache do
  @moduledoc """
  Process-wide cache of parsed pack indexes.

  Reading an object happens once per tree/blob during a walk, so re-parsing an
  `.idx` file (and re-scanning the directory) on every lookup is not viable. The
  cache keeps one entry per store (`home_dir`) holding the parsed offsets and
  the precomputed entry ends (see `Pack.entry_ends/2`).

  Invalidation is explicit: every writer that renames a pack into place calls
  `invalidate/1` (via `GitStore.pack_objects/3`). An out-of-process writer (the
  manual repack task in another VM, or another server node) cannot clear this
  VM's table, so `GitStore` reloads a store once when a packed lookup misses;
  `reload/1` is the underlying primitive. The cache does not stat files on the
  read path, so a hot walk costs one ETS lookup per object.

  The ETS table is owned by a GenServer started from
  `Cadence.Shared.Application`. When the process is not running (for example a
  bare `mix run --no-start`), `packs/1` parses on demand so reads never fail.
  """

  use GenServer

  alias Cadence.Shared.GitStore.Pack
  alias Cadence.Shared.GitStore.Pack.Index

  @table :cadence_git_pack_cache
  @pack_dir "objects/pack"
  @idx_name ~r/^pack-[0-9a-f]{40}\.idx$/
  @max_entries 1024

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    {:ok, %{}}
  end

  @doc """
  Return the parsed pack indexes for a store.

  Each entry is `%{name, pack_path, idx_path, offsets, ends, pack_checksum}`.
  Corrupt indexes, orphaned indexes, and index/pack pairs whose checksums
  disagree are skipped rather than raising.
  """
  @spec packs(Path.t()) :: [map()]
  def packs(home_dir) when is_binary(home_dir) do
    if table?() do
      cached(home_dir)
    else
      load(index_paths(home_dir))
    end
  end

  defp cached(home_dir) do
    case :ets.lookup(@table, home_dir) do
      [{^home_dir, packs}] ->
        packs

      _ ->
        packs = load(index_paths(home_dir))
        store(home_dir, packs)
        packs
    end
  rescue
    ArgumentError -> load(index_paths(home_dir))
  end

  @doc "Drop the cached indexes for a store (call after a pack is renamed in)."
  @spec invalidate(Path.t()) :: :ok
  def invalidate(home_dir) when is_binary(home_dir) do
    if table?(), do: :ets.delete(@table, home_dir)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Forget and re-read a store's packs (out-of-process writer recovery)."
  @spec reload(Path.t()) :: [map()]
  def reload(home_dir) when is_binary(home_dir) do
    :ok = invalidate(home_dir)
    packs(home_dir)
  end

  defp store(home_dir, packs) do
    # Bound memory from deleted projects: reloading is cheap and explicit.
    if :ets.info(@table, :size) >= @max_entries do
      :ets.delete_all_objects(@table)
    end

    :ets.insert(@table, {home_dir, packs})
  rescue
    ArgumentError -> :ok
  end

  defp index_paths(home_dir) do
    dir = Path.join(home_dir, @pack_dir)

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&Regex.match?(@idx_name, &1))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.sort()

      {:error, _reason} ->
        []
    end
  end

  defp load(paths) do
    Enum.flat_map(paths, fn idx_path ->
      pack_path = Index.pack_path(idx_path)

      with {:ok, %File.Stat{size: pack_size}} <- File.stat(pack_path),
           {:ok, bytes} <- File.read(idx_path),
           {:ok, index} <- Index.decode(bytes),
           true <- pack_trailer(pack_path, pack_size) == index.pack_checksum do
        [
          %{
            name: Path.basename(idx_path, ".idx"),
            pack_path: pack_path,
            idx_path: idx_path,
            offsets: index.offsets,
            ends: Pack.entry_ends(index.offsets, pack_size),
            pack_checksum: index.pack_checksum
          }
        ]
      else
        _ -> []
      end
    end)
  end

  # A mismatched pair (interrupted rename, foreign files, corruption) is not a
  # usable pack; skipping it keeps reads correct and lets a repack rewrite it.
  defp pack_trailer(path, size) when size >= 20 do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        result = :file.pread(io, size - 20, 20)
        :file.close(io)

        case result do
          {:ok, trailer} when byte_size(trailer) == 20 -> trailer
          _ -> nil
        end

      {:error, _reason} ->
        nil
    end
  end

  defp pack_trailer(_path, _size), do: nil

  defp table?(), do: :ets.whereis(@table) != :undefined
end
