defmodule Cadence.ServerWeb.SessionOptions do
  @moduledoc """
  The signed session cookie options shared by the endpoint and its tests
  (spec §12.9).

  `Plug.Session` options are fixed when the endpoint is compiled, so this is a
  pure function evaluated at compile time by `Cadence.ServerWeb.Endpoint` and
  directly by the test. There is no runtime toggle: a `MIX_ENV=prod` build is
  HTTPS-only, while dev, test, and the localhost demo stay non-`secure` so
  `http://localhost` keeps working for WebAuthn (a browser secure context).
  """

  @doc "Cookie options for a deploy environment (`:prod`, `:dev`, `:test`)."
  @spec cookie(atom()) :: keyword()
  def cookie(env) do
    [
      store: :cookie,
      key: "_cadence_key",
      signing_salt: "cadence-session",
      same_site: "Lax",
      http_only: true,
      secure: env == :prod
    ]
  end
end
