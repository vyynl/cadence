defmodule Cadence.Server.Actions.Artifacts do
  @moduledoc """
  Copies an action's `/out` volume contents into the durable artifact directory
  (spec §8.3).

  Actions are untrusted code, so collection is deliberately narrow: only
  regular files are copied (symlinks, FIFOs, sockets, and device nodes are
  skipped so a link cannot pull host files into the artifact store), the tree is
  capped by file count and total bytes, and the destination path is re-derived
  from the relative name. A collection failure is recorded on the run but never
  rewrites the exit-derived status.
  """

  @max_files 1_000

  @type error :: :too_many_files | :too_large | :io_error

  @doc "Maximum number of files collected from one run."
  @spec max_files() :: pos_integer()
  def max_files, do: @max_files

  @doc """
  Copy every regular file under `source` into `dest`, preserving relative paths.

  A missing source directory means the action produced no output and returns
  `{:ok, []}`. Returns the collected relative paths on success.
  """
  @spec collect(Path.t(), Path.t(), non_neg_integer()) ::
          {:ok, [String.t()]} | {:error, error()}
  def collect(source, dest, max_bytes) do
    with {:ok, files} <- list_files(source) do
      total = files |> Enum.map(fn {_relative, full} -> file_size(full) end) |> Enum.sum()

      cond do
        total > max_bytes -> {:error, :too_large}
        true -> copy_files(files, dest, max_bytes)
      end
    end
  end

  @doc "List the artifact files recorded under `dest` (relative paths, sorted)."
  @spec list(Path.t()) :: [%{path: String.t(), size: non_neg_integer()}]
  def list(dest) do
    case list_files(dest) do
      {:ok, files} ->
        files
        |> Enum.map(fn {relative, full} -> %{path: relative, size: file_size(full)} end)
        |> Enum.sort_by(& &1.path)

      {:error, _reason} ->
        []
    end
  end

  ## Internals

  # Walk without following symlinks: File.lstat/1 describes the entry itself,
  # and only :regular entries are collected.
  defp list_files(root) do
    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory}} ->
        case walk(root, root, [], 0) do
          {:ok, files, _count} -> {:ok, Enum.sort_by(files, &elem(&1, 0))}
          {:error, _reason} = error -> error
        end

      {:ok, _stat} ->
        {:ok, []}

      {:error, :enoent} ->
        {:ok, []}

      {:error, _reason} ->
        {:error, :io_error}
    end
  end

  defp walk(root, dir, acc, count) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.reduce_while(names, {:ok, acc, count}, fn name, {:ok, acc, count} ->
          path = Path.join(dir, name)

          case File.lstat(path) do
            {:ok, %File.Stat{type: :regular}} ->
              if count + 1 > @max_files do
                {:halt, {:error, :too_many_files}}
              else
                {:cont, {:ok, [{Path.relative_to(path, root), path} | acc], count + 1}}
              end

            {:ok, %File.Stat{type: :directory}} ->
              case walk(root, path, acc, count) do
                {:ok, next_acc, next_count} -> {:cont, {:ok, next_acc, next_count}}
                {:error, _reason} = error -> {:halt, error}
              end

            {:ok, _other} ->
              {:cont, {:ok, acc, count}}

            {:error, _reason} ->
              {:halt, {:error, :io_error}}
          end
        end)

      # A directory that vanished mid-walk contributes nothing.
      {:error, :enoent} ->
        {:ok, acc, count}

      {:error, _reason} ->
        {:error, :io_error}
    end
  end

  defp copy_files(files, dest, total_cap) do
    Enum.reduce_while(files, {:ok, []}, fn {relative, source}, {:ok, copied} ->
      target = Path.join(dest, relative)

      with :ok <- mkdir(Path.dirname(target)),
           :ok <- copy(source, target, total_cap) do
        {:cont, {:ok, [relative | copied]}}
      else
        {:error, _reason} ->
          # Do not leave a half-collected artifact set behind.
          File.rm_rf(dest)
          {:halt, {:error, :io_error}}
      end
    end)
    |> case do
      {:ok, copied} -> {:ok, Enum.reverse(copied)}
      {:error, _reason} = error -> error
    end
  end

  defp mkdir(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, _reason} -> {:error, :io_error}
    end
  end

  # Bind the path to the inode seen by lstat, read at most `max_bytes + 1`
  # through one descriptor, then confirm the path still refers to that regular
  # file. A just-in-time swap to a symlink (for example /etc/passwd or
  # /dev/zero) is bounded by the read limit and discarded by the inode check.
  defp copy(source, target, max_bytes) do
    with {:ok, %File.Stat{type: :regular, inode: inode, size: size}} <- File.lstat(source),
         true <- size <= max_bytes,
         {:ok, content} <- read_bounded(source, max_bytes + 1),
         true <- byte_size(content) <= max_bytes,
         {:ok, %File.Stat{type: :regular, inode: ^inode}} <- File.lstat(source),
         :ok <- File.write(target, content) do
      :ok
    else
      _other -> {:error, :io_error}
    end
  end

  defp read_bounded(path, limit) do
    case :file.open(path, [:read, :raw, :binary]) do
      {:ok, io} ->
        try do
          read_chunks(io, limit, [])
        after
          :file.close(io)
        end

      {:error, _reason} ->
        {:error, :io_error}
    end
  end

  defp read_chunks(_io, 0, acc), do: {:ok, IO.iodata_to_binary(acc)}

  defp read_chunks(io, remaining, acc) do
    case :file.read(io, min(remaining, 65_536)) do
      {:ok, data} -> read_chunks(io, remaining - byte_size(data), [acc | data])
      :eof -> {:ok, IO.iodata_to_binary(acc)}
      {:error, _reason} -> {:error, :io_error}
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      {:error, _reason} -> 0
    end
  end
end
