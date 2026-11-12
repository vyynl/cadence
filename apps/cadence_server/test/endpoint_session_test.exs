defmodule Cadence.ServerWeb.EndpointSessionTest do
  @moduledoc """
  Session-cookie hardening (spec §12.9).

  `Plug.Session` options are fixed when the endpoint is compiled, so the test
  exercises the same function the endpoint uses at compile time instead of
  introspecting a running cookie. The prod compile is also part of the merge
  gate (`MIX_ENV=prod mix compile`), which is what makes the attribute path
  real.
  """

  use ExUnit.Case, async: true

  alias Cadence.ServerWeb.SessionOptions

  test "production cookies are HTTPS-only and keep the hardened flags" do
    options = SessionOptions.cookie(:prod)

    assert options[:secure] == true
    assert options[:http_only] == true
    assert options[:same_site] == "Lax"
    assert options[:key] == "_cadence_key"
    assert options[:store] == :cookie
  end

  test "dev and test keep secure off so localhost WebAuthn works" do
    for env <- [:dev, :test] do
      options = SessionOptions.cookie(env)

      refute options[:secure]
      assert options[:http_only] == true
      assert options[:same_site] == "Lax"
    end
  end
end
