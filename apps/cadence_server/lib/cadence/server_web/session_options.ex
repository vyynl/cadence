defmodule Cadence.ServerWeb.SessionOptions do
  @moduledoc """
  Signed session-cookie options for the endpoint, the LiveView socket, and the
  remember-me cookie (spec §12.9).

  A deployment may publish through a public HTTPS origin while the operator
  signs in over a LAN or Tailscale address, where a `Secure` cookie would never
  come back. `CAD_SESSION_COOKIE_SECURE` decides which hosts get the flag:

    * `public` (default) — only the host in `CAD_PUBLIC_URL`, and only when that
      origin is HTTPS. The public origin keeps the hardening; a private address
      gets a usable session.
    * `always` — every host, the behaviour of a deployment that only serves
      HTTPS.
    * `never` — no host (dev, test, and a deliberate opt-out).

  Matching on the request host rather than the connection scheme is deliberate:
  the app is always plain HTTP behind Caddy or a tunnel, so a scheme rule would
  need `X-Forwarded-Proto` trust and a proxy that drops the header would
  silently downgrade the public origin.

  `base/0` is the static half. It is all the LiveView socket needs, because
  reading a cookie ignores the flag.
  """

  alias Cadence.ServerWeb.Metadata

  @modes [:public, :always, :never]

  @doc "Cookie options that do not depend on the request."
  @spec base() :: keyword()
  def base do
    [
      store: :cookie,
      key: "_cadence_key",
      signing_salt: "cadence-session",
      same_site: "Lax",
      http_only: true
    ]
  end

  @doc "Cookie options for one request host."
  @spec cookie(String.t() | nil) :: keyword()
  def cookie(host), do: Keyword.put(base(), :secure, secure?(host))

  @doc """
  Whether this request's cookie carries the `Secure` flag.

  `host` is the request's `Host` header (`Plug.Conn.host`), without a port.
  """
  @spec secure?(String.t() | nil) :: boolean()
  def secure?(host) do
    case mode() do
      :always -> true
      :never -> false
      :public -> public_host?(host)
    end
  end

  @doc "The configured mode (`CAD_SESSION_COOKIE_SECURE`, `:public` by default)."
  @spec mode() :: :public | :always | :never
  def mode do
    case Application.get_env(:cadence_server, :session_cookie_secure, :public) do
      mode when mode in @modes -> mode
      _other -> :public
    end
  end

  defp public_host?(host) when is_binary(host) do
    uri = URI.parse(Metadata.public_url())

    uri.scheme == "https" and is_binary(uri.host) and
      String.downcase(host) == String.downcase(uri.host)
  end

  defp public_host?(_host), do: false
end
