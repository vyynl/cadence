defmodule Cadence.Daemon.Dirs do
  @moduledoc """
  Ownership-hardening helpers and well-known paths for daemon data.
  """

  @doc "The daemon state directory (socket, cache, DB). Default: `~/.local/state/cadence`."
  @spec state_dir() :: Path.t()
  def state_dir do
    System.get_env("CAD_STATE_DIR") ||
      Path.join(System.user_home!(), ".local/state/cadence")
  end

  @doc "Root under which per-project bare Git object stores live."
  @spec git_root() :: Path.t()
  def git_root do
    Path.join(state_dir(), "git")
  end

  @doc "Path of the daemon's Unix socket."
  @spec socket_path() :: Path.t()
  def socket_path do
    Path.join(state_dir(), "daemon.sock")
  end

  @doc """
  Creates `path` (and any missing parents) with owner-only permissions (`0700`).

  Idempotent; safe to call on every start.
  """
  @spec ensure!(Path.t()) :: :ok
  def ensure!(path) do
    File.mkdir_p!(path)
    File.chmod!(path, 0o700)
    :ok
  end

  @doc """
  Creates the parent directory of a configured SQLite database owner-only.

  `:memory:` (tests), an unset database, and a bare relative filename (whose
  `Path.dirname/1` is `"."`) are no-ops, so callers can pass
  `repo.config()[:database]` without branching and never chmod the current
  directory.
  """
  @spec ensure_repo_dir!(Path.t() | nil) :: :ok
  def ensure_repo_dir!(path) when is_binary(path) and path != ":memory:" do
    case Path.dirname(path) do
      "." -> :ok
      dir -> ensure!(dir)
    end
  end

  def ensure_repo_dir!(_path), do: :ok
end
