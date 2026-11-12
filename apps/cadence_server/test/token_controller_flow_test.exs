defmodule Cadence.ServerWeb.TokenControllerFlowTest do
  @moduledoc """
  Pins what the hand-built HTML strings in `TokenController` used to get wrong:
  every interpolation is escaped, and the pages render through the real
  `:browser` pipeline (session -> CSRF -> response) with no app layout.
  """

  use Cadence.ServerWeb.ConnCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Cadence.Server.Accounts.User
  alias Cadence.ServerWeb.TokenHTML

  setup do
    user = Ash.Seed.seed!(User, %{email: "tokens-flow@example.com", name: "Token Flow"})
    {:ok, user: user}
  end

  describe "template escaping" do
    # `embed_templates` names the generated function after the template file
    # without its extensions, so the render name is "new"/"create" — not
    # "new.html", which has no `render/2` fallback on these modules.
    test "new.html escapes the signed-in email and the CSRF token" do
      html =
        Phoenix.Template.render_to_string(TokenHTML, "new", "html", %{
          email: "<script>alert(1)</script>",
          csrf: "\"><script>alert(2)</script>"
        })

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      assert html =~ "&lt;script&gt;alert(2)&lt;/script&gt;"
      assert html =~ ~s(action="/auth/tokens")
    end

    test "create.html escapes the plaintext API key" do
      html =
        Phoenix.Template.render_to_string(TokenHTML, "create", "html", %{
          plaintext: "<script>alert(1)</script>"
        })

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    end
  end

  describe "GET then POST /auth/tokens through the browser pipeline" do
    test "issues a key once, uncached, without the app layout", %{conn: conn, user: user} do
      conn =
        conn
        |> signed_conn(user)
        |> get("/auth/tokens/new")

      assert html_response(conn, 200)
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      refute conn.resp_body =~ "site-header"

      conn = post(conn, "/auth/tokens", %{"_csrf_token" => csrf_token!(conn), "name" => "daemon"})

      assert conn.status == 201
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/html"
      assert conn.resp_body =~ "cad_"
      assert conn.resp_body =~ "CAD_AUTH_TOKEN"
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      refute conn.resp_body =~ "site-header"
      refute conn.resp_body =~ "<nav"
    end
  end

  defp csrf_token!(conn) do
    case Regex.run(~r/name="_csrf_token" value="([^"]+)"/, conn.resp_body) do
      [_match, token] -> token
      nil -> flunk("the token form carried no CSRF token")
    end
  end

  defp signed_conn(conn, user) do
    conn = init_test_session(conn, %{})
    {conn, _session} = Cadence.ServerWeb.UserAuth.log_in(conn, user)
    conn
  end
end
