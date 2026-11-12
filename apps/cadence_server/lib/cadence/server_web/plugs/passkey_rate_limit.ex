defmodule Cadence.ServerWeb.Plugs.PasskeyRateLimit do
  @moduledoc """
  Rate-limits WebAuthn ceremony POSTs per client IP (plan §8).

  The bound comes from the WebAuthn config (`CAD_WEBAUTHN_RATE_LIMIT` per
  `CAD_WEBAUTHN_RATE_SCALE` milliseconds) and is disabled when the limit is zero
  or negative. The client address is the connection's `remote_ip`; behind a
  reverse proxy this is the proxy address unless the deployment sets
  `Plug.RewriteOn` (out of scope for this slice).
  """

  @behaviour Plug

  alias Cadence.Server.Passkeys.Config

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    config = Config.get()

    if config.rate_limit > 0 do
      case Cadence.Server.PasskeyRateLimit.hit(
             {:webauthn, conn.remote_ip},
             config.rate_scale,
             config.rate_limit
           ) do
        {:allow, _count} -> conn
        {:deny, retry_after_ms} -> deny(conn, retry_after_ms)
      end
    else
      conn
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
end
