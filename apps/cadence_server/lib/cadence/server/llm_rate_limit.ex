defmodule Cadence.Server.LLMRateLimit do
  @moduledoc """
  Shared rate limiter for server-side LLM calls (spec §9).

  Backed by Hammer's ETS fix-window algorithm, mirroring
  `Cadence.Daemon.LLMRateLimit`. Limits and window are read from
  `CAD_MELD_RATE_LIMIT` / `CAD_MELD_RATE_SCALE` at call time.
  """

  use Hammer, backend: :ets, algorithm: :fix_window
end
