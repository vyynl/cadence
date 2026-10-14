defmodule Cadence.Daemon.Env do
  @moduledoc """
  Reads daemon runtime configuration.

  Populated from `CAD_*` env vars in `config/runtime.exs`; this module provides
  the typed accessors and defaults so callers don't each reach into
  `Application.get_env/3`.
  """

  @doc "The local user's UUID, used as a node's `created_by` and the owner id."
  @spec local_user_id() :: Ecto.UUID.t() | nil
  def local_user_id, do: Application.get_env(:cadence_daemon, :local_user_id)

  @doc "Entry names skipped when snapshotting a working tree (`.git` is always skipped)."
  @spec ignore_names() :: [String.t()]
  def ignore_names, do: Application.get_env(:cadence_daemon, :ignore, [])
end
