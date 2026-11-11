defmodule Cadence.Server.SyncRateLimit do
  @moduledoc """
  Coarse outer bound on `/sync/*` requests, keyed per authenticated user
  (spec §10.1).

  Backed by Hammer's ETS fix-window algorithm, mirroring
  `Cadence.Server.LLMRateLimit`. The limit and window are read at call time by
  `Cadence.ServerWeb.Plugs.SyncRateLimit` from `CAD_SYNC_RATE_LIMIT` /
  `CAD_SYNC_RATE_SCALE`, so a non-positive limit disables the bound without a
  restart.

  This is deliberately *not* the meld bound: `Cadence.Server.MeldWorker` keeps
  its own per-project limiter as the inner, expensive-call limit.

  `:fix_window` windows are wall-clock aligned, so a burst spanning a boundary
  can permit up to 2× the limit in a short span. Changing `CAD_SYNC_RATE_SCALE`
  mid-window starts a fresh bucket, because the window number is part of the
  key.
  """

  use Hammer, backend: :ets, algorithm: :fix_window
end
