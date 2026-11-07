defmodule Cadence.Server.Actions.Staging do
  @moduledoc """
  Materializes one node snapshot into a run directory and builds a Docker build
  context from it (spec §8.3).

  Staging reuses the bounded `GitStore.walk_blobs/3` walk the public read path
  uses, so the same caps that decide a snapshot is verifiable also decide it can
  run. The returned blob list lets the runner apply the content quarantine check
  without walking the store a second time.

  Paths come from tree entries, which are client-pushed: each segment is
  re-validated here so a crafted object cannot escape the run directory. Files
  are written with `File.write/2` (never as links), so an action cannot inherit
  a symlink planted by an earlier run.
  """

  alias Cadence.Shared.GitStore

  @type caps :: %{max_files: non_neg_integer(), max_bytes: non_neg_integer()}
  @type blob :: %{path: String.t(), ref: String.t(), size: non_neg_integer(), content: binary()}

  @type error :: :unsafe_path | :write_failed | :build_context_failed | atom()

  @doc """
  Walk `commit_sha` under the given caps without writing anything.

  The caller scans the returned blobs for quarantine **before** calling
  `write/2`, so a secret-bearing snapshot is never materialized on the action
  volume.
  """
  @spec walk(GitStore.t(), String.t(), caps()) :: {:ok, [blob()]} | {:error, atom()}
  def walk(repo, commit_sha, %{max_files: max_files, max_bytes: max_bytes}) do
    GitStore.walk_blobs(repo, commit_sha, max_files: max_files, max_bytes: max_bytes)
  end

  @doc "Write walked blobs under `dest`, replacing any previous run directory."
  @spec write([blob()], Path.t()) :: :ok | {:error, :unsafe_path | :write_failed}
  def write(blobs, dest) when is_list(blobs) and is_binary(dest) do
    File.rm_rf(dest)

    case mkdir(dest) do
      :ok ->
        case write_blobs(blobs, dest) do
          :ok ->
            :ok

          {:error, _reason} = error ->
            File.rm_rf(dest)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc "`walk/3` then `write/2` (convenience for callers that already scanned)."
  @spec stage(GitStore.t(), String.t(), Path.t(), caps()) ::
          {:ok, [blob()]} | {:error, error()}
  def stage(repo, commit_sha, dest, caps) do
    with {:ok, blobs} <- walk(repo, commit_sha, caps),
         :ok <- write(blobs, dest) do
      {:ok, blobs}
    end
  end

  @doc """
  Build a gzipped tar of `files` (paths relative to `code_dir`) for the Docker
  build context.

  Archive names are relative, so the host paths never leak into the image
  context. No process working directory is changed.
  """
  @spec build_context(Path.t(), [String.t()]) :: {:ok, binary()} | {:error, :build_context_failed}
  def build_context(code_dir, files) when is_binary(code_dir) and is_list(files) do
    entries =
      files
      |> Enum.filter(&safe_context_path?/1)
      |> Enum.map(fn relative ->
        {String.to_charlist(relative), String.to_charlist(Path.join(code_dir, relative))}
      end)

    work_dir =
      Path.join(
        System.tmp_dir!(),
        "cadence-action-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    tar_path = Path.join(work_dir, "context.tar")

    try do
      # A private 0700 directory keeps the build context out of reach of local
      # users and prevents a pre-created symlink from redirecting the write.
      case File.mkdir(work_dir) do
        :ok -> :ok
        {:error, _reason} -> throw(:build_context_failed)
      end

      case File.chmod(work_dir, 0o700) do
        :ok -> :ok
        {:error, _reason} -> throw(:build_context_failed)
      end

      case :erl_tar.create(String.to_charlist(tar_path), entries, [:compressed]) do
        :ok ->
          case File.read(tar_path) do
            {:ok, binary} -> {:ok, binary}
            {:error, _reason} -> {:error, :build_context_failed}
          end

        _error ->
          {:error, :build_context_failed}
      end
    rescue
      _error -> {:error, :build_context_failed}
    catch
      :throw, :build_context_failed -> {:error, :build_context_failed}
      _kind, _reason -> {:error, :build_context_failed}
    after
      File.rm_rf(work_dir)
    end
  end

  def build_context(_code_dir, _files), do: {:error, :build_context_failed}

  ## Internals

  defp write_blobs(blobs, dest) do
    Enum.reduce_while(blobs, :ok, fn blob, :ok ->
      case write_blob(blob, dest) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp write_blob(%{path: path, content: content}, dest) do
    with {:ok, segments} <- safe_segments(path),
         full = Path.join([dest | segments]),
         :ok <- ensure_inside(full, dest),
         :ok <- mkdir(Path.dirname(full)),
         :ok <- write_file(full, content) do
      :ok
    end
  end

  defp safe_segments(path) when is_binary(path) do
    segments = String.split(path, "/")

    if segments != [] and Enum.all?(segments, &safe_segment?/1) do
      {:ok, segments}
    else
      {:error, :unsafe_path}
    end
  end

  defp safe_segments(_path), do: {:error, :unsafe_path}

  defp safe_segment?(segment) do
    segment not in ["", ".", ".."] and
      not String.contains?(segment, ["\\", <<0>>])
  end

  defp safe_context_path?(path) when is_binary(path) do
    match?({:ok, _segments}, safe_segments(path))
  end

  defp safe_context_path?(_path), do: false

  defp ensure_inside(full, dest) do
    if String.starts_with?(full, dest <> "/"), do: :ok, else: {:error, :unsafe_path}
  end

  defp mkdir(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, _reason} -> {:error, :write_failed}
    end
  end

  defp write_file(path, content) do
    case File.write(path, content) do
      :ok -> :ok
      {:error, _reason} -> {:error, :write_failed}
    end
  end
end
