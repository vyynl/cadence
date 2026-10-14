defmodule Cadence.Daemon.Dirs do
  @moduledoc """
  Ownership-hardening helpers and well-known paths for daemon data.
  """

  @doc "The daemon state directory (socket, cache, DB). Default: `~/.local/state/cadence`."
  @spec state_dir() :: Path.t()
  def state_dir do
    System.get_env("CAD_STATE_DIR", Path.join(System.user_home!(), ".local/state/cadence"))
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
end
