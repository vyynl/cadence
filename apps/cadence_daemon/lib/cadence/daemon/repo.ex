defmodule Cadence.Daemon.Repo do
  @moduledoc """
  The daemon's local SQLite repository, backed by `ecto_sqlite3`.

  Points at the shared schemas in `cadence_shared` (`Cadence.Shared.Node`,
  `Cadence.Shared.Project`, `Cadence.Shared.Membership`).
  """

  use Ecto.Repo,
    otp_app: :cadence_daemon,
    adapter: Ecto.Adapters.SQLite3
end
