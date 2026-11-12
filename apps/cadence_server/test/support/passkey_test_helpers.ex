defmodule Cadence.ServerWeb.PasskeyTestHelpers do
  @moduledoc false

  import ExUnit.Assertions, only: [flunk: 1]
  import Phoenix.ConnTest
  import Plug.Conn

  alias Cadence.Server.Accounts.User
  alias Cadence.Server.Passkeys

  @endpoint Cadence.ServerWeb.Endpoint

  @doc "Signs a conn in with the same JWT-jti session shape the app stores."
  def signed_conn(conn, %User{} = user) do
    {:ok, _token, claims} = AshAuthentication.Jwt.token_for_user(user)
    subject_name = AshAuthentication.Info.authentication_subject_name!(User)

    conn
    |> init_test_session(%{})
    |> put_session(to_string(subject_name), claims["jti"] <> ":" <> claims["sub"])
  end

  @doc "Masks the CSRF token rendered into the app layout's meta tag."
  def csrf_token(conn) do
    case Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, conn.resp_body) do
      [_match, token] -> token
      nil -> flunk("the page carried no CSRF meta token")
    end
  end

  @doc """
  Seeds the session's CSRF state and returns the masked token a browser would
  send in `x-csrf-token`.

  Use it with `enable_csrf/1` when a test needs real forgery protection; the
  ConnTest default skips the check.
  """
  def csrf_session(conn) do
    state = Plug.CSRFProtection.dump_state()
    conn = init_test_session(conn, %{"_csrf_token" => state})
    {conn, Plug.CSRFProtection.get_csrf_token()}
  end

  def enable_csrf(conn), do: put_private(conn, :plug_skip_csrf_protection, false)

  def challenge(conn), do: get_session(conn, Passkeys.session_key())

  @doc """
  Posts a JSON body with the headers the browser script sends.

  The conn must not be recycled between setup and the request (`build_conn/0`
  and `init_test_session/2` already satisfy that). Pass `csrf:` to include the
  token header.
  """
  def json_post(conn, path, payload, opts \\ []) do
    conn = put_req_header(conn, "content-type", "application/json")

    conn =
      case Keyword.get(opts, :csrf) do
        nil -> conn
        token -> put_req_header(conn, "x-csrf-token", token)
      end

    post(conn, path, Jason.encode!(payload))
  end

  @doc "Base64url registration payload matching `passkeys.js`."
  def registration_payload(response, label, transports \\ ["usb"]) do
    %{
      "id" => Base.url_encode64(response.credential_id, padding: false),
      "rawId" => Base.url_encode64(response.credential_id, padding: false),
      "type" => "public-key",
      "response" => %{
        "attestationObject" => Base.url_encode64(response.attestation_object, padding: false),
        "clientDataJSON" => Base.url_encode64(response.client_data_json, padding: false)
      },
      "transports" => transports,
      "label" => label
    }
  end

  @doc "Base64url assertion payload matching `passkeys.js`."
  def assertion_payload(response, return_to \\ "/") do
    %{
      "id" => Base.url_encode64(response.credential_id, padding: false),
      "rawId" => Base.url_encode64(response.credential_id, padding: false),
      "type" => "public-key",
      "response" => %{
        "authenticatorData" => Base.url_encode64(response.authenticator_data, padding: false),
        "clientDataJSON" => Base.url_encode64(response.client_data_json, padding: false),
        "signature" => Base.url_encode64(response.signature, padding: false),
        "userHandle" => nil
      },
      "return_to" => return_to
    }
  end
end
