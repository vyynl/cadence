defmodule Cadence.Server.PasskeyRateLimit do
  @moduledoc """
  IP-keyed rate limiter for the two WebAuthn ceremony POSTs (plan §8).

  Backed by Hammer's ETS fix-window algorithm, mirroring
  `Cadence.Server.SyncRateLimit`. The limit and window are read at call time by
  `Cadence.ServerWeb.Plugs.PasskeyRateLimit` from `CAD_WEBAUTHN_RATE_LIMIT` /
  `CAD_WEBAUTHN_RATE_SCALE`, so a non-positive limit disables the bound without
  a restart.

  A denial is a halted `429` with `Retry-After` in whole seconds (rounded up,
  at least `1`) and `{"error": "rate_limited"}`.
  """

  use Hammer, backend: :ets, algorithm: :fix_window
end
