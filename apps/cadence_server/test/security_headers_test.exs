defmodule Cadence.ServerWeb.SecurityHeadersTest do
  use Cadence.ServerWeb.ConnCase, async: true

  @expected_csp "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' https:; font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'self'"

  test "the portfolio sends the exact Content-Security-Policy", %{conn: conn} do
    conn = get(conn, "/")

    assert html_response(conn, 200)
    assert [policy] = get_resp_header(conn, "content-security-policy")
    assert policy == @expected_csp
  end

  test "a LiveView dead render also carries the policy", %{conn: conn} do
    conn = get(conn, "/p/missing")

    assert [policy] = get_resp_header(conn, "content-security-policy")
    assert policy == @expected_csp
  end

  test "the anonymous member-route redirect carries the policy", %{conn: conn} do
    conn = get(conn, "/p/missing/reviews")

    assert redirected_to(conn) == "/p/missing"
    assert [policy] = get_resp_header(conn, "content-security-policy")
    assert policy == @expected_csp
  end
end
