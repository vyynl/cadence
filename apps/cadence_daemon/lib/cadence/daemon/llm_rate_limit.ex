defmodule Cadence.Daemon.LLMRateLimit do
  @moduledoc """
  Shared rate limiter for all LLM calls in the daemon (spec §5.2, §9.6).

  Backed by Hammer's ETS fix-window algorithm. Limits and window are read from
  `CAD_LLM_RATE_LIMIT` / `CAD_LLM_RATE_SCALE` at call time.
  """

  use Hammer, backend: :ets, algorithm: :fix_window
end
