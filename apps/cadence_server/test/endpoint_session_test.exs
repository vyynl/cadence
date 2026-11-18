defmodule Cadence.ServerWeb.EndpointSessionTest do
  @moduledoc """
  Session-cookie hardening (spec §12.9).

  `CAD_SESSION_COOKIE_SECURE` decides which hosts get the `Secure` flag, because
  a deployment can publish through a public HTTPS origin while the operator
  signs in over a LAN or Tailscale address. The rules are exercised through
  `SessionOptions` and through the plug that the endpoint runs, so both the
  decision and its wiring are covered.
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Test

  alias Cadence.ServerWeb.Session
  alias Cadence.ServerWeb.SessionOptions
  alias Cadence.ServerWeb.UserAuth

  @endpoint Cadence.ServerWeb.Endpoint

  setup do
    mode = Application.get_env(:cadence_server, :session_cookie_secure)
    public_url = Application.get_env(:cadence_server, :public_url)

    on_exit(fn ->
      Application.put_env(:cadence_server, :session_cookie_secure, mode)
      Application.put_env(:cadence_server, :public_url, public_url)
    end)

    :ok
  end

  defp set_origin(mode, public_url) do
    Application.put_env(:cadence_server, :session_cookie_secure, mode)
    Application.put_env(:cadence_server, :public_url, public_url)
  end

  test "public mode marks only the published HTTPS host" do
    set_origin(:public, "https://cadence.example.com")

    assert SessionOptions.secure?("cadence.example.com")
    assert SessionOptions.secure?("CADENCE.EXAMPLE.COM")

    refute SessionOptions.secure?("192.168.1.5")
    refute SessionOptions.secure?("100.107.198.51")
    refute SessionOptions.secure?("truenas-scale.tail26eb8b.ts.net")
    refute SessionOptions.secure?(nil)
  end

  test "public mode stays off when the published origin is plain HTTP" do
    set_origin(:public, "http://localhost:4000")

    refute SessionOptions.secure?("localhost")
    refute SessionOptions.secure?("192.168.1.5")
  end

  test "always and never are explicit overrides" do
    set_origin(:always, "https://cadence.example.com")

    assert SessionOptions.secure?("cadence.example.com")
    assert SessionOptions.secure?("192.168.1.5")

    set_origin(:never, "https://cadence.example.com")

    refute SessionOptions.secure?("cadence.example.com")
    refute SessionOptions.secure?("192.168.1.5")
  end

  test "the cookie keeps the hardened flags" do
    options = SessionOptions.cookie("cadence.example.com")

    assert options[:http_only] == true
    assert options[:same_site] == "Lax"
    assert options[:key] == "_cadence_key"
    assert options[:store] == :cookie
    assert options[:signing_salt] == "cadence-session"
  end

  test "the session plug writes Secure only for the published host" do
    set_origin(:public, "https://cadence.example.com")

    assert session_cookie("cadence.example.com")[:secure] == true
    refute session_cookie("100.107.198.51")[:secure]
  end

  test "the endpoint applies the rule to a real request" do
    set_origin(:public, "https://cadence.example.com")

    public = build_conn() |> Map.put(:host, "cadence.example.com") |> get("/sign-in")

    assert public.resp_cookies["_cadence_key"][:secure] == true

    private = build_conn() |> Map.put(:host, "192.168.1.10") |> get("/sign-in")

    refute private.resp_cookies["_cadence_key"][:secure]
  end

  test "the remember-me cookie follows the same host rule" do
    set_origin(:public, "https://cadence.example.com")

    assert remember_me_cookie("cadence.example.com")[:secure] == true
    refute remember_me_cookie("192.168.1.5")[:secure]
  end

  # `Plug.Test.conn/2` carries no secret, and both cookies are signed.
  defp build(host) do
    :get
    |> conn("/")
    |> Map.put(:host, host)
    |> Map.put(:secret_key_base, String.duplicate("s", 64))
  end

  defp session_cookie(host) do
    host
    |> build()
    |> Session.call([])
    |> Plug.Conn.fetch_session()
    |> Plug.Conn.put_session(:probe, "1")
    |> Plug.Conn.send_resp(200, "ok")
    |> Map.fetch!(:resp_cookies)
    |> Map.fetch!("_cadence_key")
  end

  defp remember_me_cookie(host) do
    host
    |> build()
    |> UserAuth.put_remember_me_cookie("token")
    |> Map.fetch!(:resp_cookies)
    |> Map.fetch!(UserAuth.remember_me_cookie())
  end
end
