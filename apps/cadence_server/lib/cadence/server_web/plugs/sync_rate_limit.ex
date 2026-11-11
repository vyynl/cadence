defmodule Cadence.ServerWeb.Plugs.SyncRateLimit do
  @moduledoc """
  Rate-limits `/sync/*` per authenticated user (spec §10.1).

  Runs after `Cadence.ServerWeb.AuthPlug`, so the key is the Ash API key's
  user, never the raw PAT: one user's daemon cannot starve another's. A
  non-positive `CAD_SYNC_RATE_LIMIT` disables the bound.

  A denial is a halted `429` with `Retry-After` in whole seconds (rounded up,
  at least `1`) and `{"error": "rate_limited"}`.

  The meld limiter (`Cadence.Server.MeldWorker`) stays the inner, per-project
  bound; this is the coarse outer bound for the whole sync surface.
  """

  @behaviour Plug

  alias Cadence.Server.SyncRateLimit

  @default_limit 300
  @default_scale 60_000

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case limit() do
      disabled when disabled <= 0 ->
        conn

      limit ->
        case SyncRateLimit.hit({:sync, conn.assigns.current_user.id}, scale(), limit) do
          {:allow, _count} -> conn
          {:deny, retry_after_ms} -> deny(conn, retry_after_ms)
        end
    end
  end

  @doc false
  # Read at call time so an operator (or a focused test) can change the bound
  # without a restart, matching `MeldWorker`.
  def limit, do: config_int(:sync_rate_limit, @default_limit)

  @doc false
  # A zero or negative window would make Hammer divide by zero; keep the
  # default instead of raising from a request.
  def scale do
    case config_int(:sync_rate_scale, @default_scale) do
      value when value > 0 -> value
      _other -> @default_scale
    end
  end

  defp deny(conn, retry_after_ms) do
    retry_after = max(div(retry_after_ms + 999, 1_000), 1)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.put_resp_header("retry-after", Integer.to_string(retry_after))
    |> Plug.Conn.send_resp(429, Jason.encode!(%{error: "rate_limited"}))
    |> Plug.Conn.halt()
  end

  defp config_int(key, default) do
    case Application.get_env(:cadence_server, key, default) do
      value when is_integer(value) -> value
      _other -> default
    end
  end
end
