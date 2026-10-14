defmodule Cadence.Daemon.API do
  @moduledoc """
  Unix-socket HTTP API (Bandit + Plug) for the Neovim plugin.

  The socket has no authentication, so it must be owner-only (`0600`). The
  parent state dir is already `0700`; after Bandit binds the socket we chmod
  it to `0600` explicitly (Erlang's Unix-socket bind does not accept a mode).
  """

  alias Cadence.Daemon.Dirs

  @doc "Path of the Unix socket, overridable via `:socket_path` in opts."
  def socket_path do
    Application.get_env(:cadence_daemon, :socket_path) || Dirs.socket_path()
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  def start_link(opts \\ []) do
    path = Keyword.get(opts, :socket_path, socket_path())
    path |> Path.dirname() |> Dirs.ensure!()
    rm_stale_socket(path)

    bandit_opts =
      opts
      |> Keyword.delete(:socket_path)
      |> Keyword.put_new(:plug, Cadence.Daemon.API.Router)
      |> Keyword.put_new(:ip, {:local, path})
      |> Keyword.put_new(:port, 0)

    case Bandit.start_link(bandit_opts) do
      {:ok, pid} ->
        File.chmod!(path, 0o600)
        {:ok, pid}

      other ->
        other
    end
  end

  defp rm_stale_socket(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :other}} -> File.rm(path)
      _ -> :ok
    end
  end
end
