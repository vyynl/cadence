defmodule Cadence.ServerWeb.PasskeySessionController do
  @moduledoc """
  Passwordless sign-in with a security key or passkey (plan §7.6).

  `new/2` mints a discoverable-credential authentication challenge, stores it in
  the signed session, and renders the browser options. `create/2` consumes the
  challenge exactly once, verifies the assertion through
  `Cadence.Server.Passkeys`, advances the sign counter, and then establishes the
  AshAuthentication session.

  Failure copy is deliberately generic for every verification failure (wrong
  key, tampered assertion, unknown credential, replay, expired challenge) so the
  endpoint never reveals whether an account or credential exists.
  """

  use Cadence.ServerWeb, :controller

  import AshAuthentication.Plug.Helpers, only: [store_in_session: 2]

  alias Cadence.Server.Accounts
  alias Cadence.Server.Accounts.User
  alias Cadence.Server.Passkeys
  alias Cadence.ServerWeb.PasskeyHelpers

  @generic_failure "That key could not sign you in. Try again or use another sign-in method."

  def new(conn, params) do
    PasskeyHelpers.with_enabled(conn, fn conn ->
      case Passkeys.authentication_challenge() do
        {:ok, %{public_key: options, challenge: challenge}} ->
          conn
          |> put_session(Passkeys.session_key(), challenge)
          |> render(:new,
            page_title: "Sign in with a security key",
            page_description: "Sign in to Cadence with a security key or passkey.",
            options_json: Jason.encode!(options),
            return_to: safe_return_to(Map.get(params, "return_to"))
          )

        {:error, _reason} ->
          conn
          |> put_flash(
            :error,
            "Security-key sign-in is unavailable right now. Try another sign-in method."
          )
          |> redirect(to: "/sign-in")
      end
    end)
  end

  def create(conn, params) do
    PasskeyHelpers.with_enabled(conn, fn conn ->
      # One ceremony per challenge: remove it before any verification work.
      challenge = get_session(conn, Passkeys.session_key())
      conn = delete_session(conn, Passkeys.session_key())

      with {:ok, response} <- decode_assertion(params),
           {:ok, result} <- Passkeys.verify_authentication(challenge, response),
           {:ok, _credential} <-
             Passkeys.record_use(
               result.user_id,
               result.credential.credential_id,
               result.sign_count
             ),
           {:ok, user} <- fetch_user(result.user_id),
           {:ok, conn} <- sign_in(conn, user) do
        PasskeyHelpers.respond(
          conn,
          :ok,
          "Signed in with a security key.",
          safe_return_to(Map.get(params, "return_to"))
        )
      else
        _failure ->
          PasskeyHelpers.respond(conn, :error, @generic_failure, "/auth/passkeys/sign-in")
      end
    end)
  end

  # -- request decoding ------------------------------------------------------

  defp decode_assertion(params) when is_map(params) do
    response = Map.get(params, "response", %{})

    with {:ok, credential_id} <- decode_b64(Map.get(params, "rawId")),
         {:ok, authenticator_data} <- decode_b64(Map.get(response, "authenticatorData")),
         {:ok, signature} <- decode_b64(Map.get(response, "signature")),
         {:ok, client_data_json} <- decode_b64(Map.get(response, "clientDataJSON")) do
      {:ok,
       %{
         credential_id: credential_id,
         authenticator_data: authenticator_data,
         signature: signature,
         client_data_json: client_data_json
       }}
    else
      _ -> {:error, :invalid_assertion}
    end
  end

  defp decode_assertion(_params), do: {:error, :invalid_assertion}

  defp decode_b64(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> :error
    end
  end

  defp decode_b64(_value), do: :error

  defp fetch_user(user_id) do
    case Ash.get(User, user_id, domain: Accounts) do
      {:ok, %User{} = user} -> {:ok, user}
      _other -> {:error, :unknown_user}
    end
  end

  # `store_in_session/2` reads a JWT from `__metadata__.token` for the
  # `:jti` session identifier. A user loaded from the database has no token
  # metadata, so mint the same kind of token the OAuth/password strategies do
  # before handing the record to the helper. `configure_session(renew: true)`
  # runs first so the pre-authentication session cannot be reused.
  defp sign_in(conn, user) do
    case AshAuthentication.Jwt.token_for_user(user) do
      {:ok, token, _claims} ->
        user = %{user | __metadata__: Map.put(user.__metadata__, :token, token)}

        {:ok, conn |> configure_session(renew: true) |> store_in_session(user)}

      _error ->
        {:error, :session_error}
    end
  end

  # -- return path -----------------------------------------------------------

  @doc false
  # Only a local absolute path is accepted; `//host` and backslashes would turn
  # into an open redirect when handed to the browser.
  def safe_return_to(value) when is_binary(value) do
    cond do
      value == "" -> "/"
      not String.starts_with?(value, "/") -> "/"
      String.starts_with?(value, "//") -> "/"
      String.contains?(value, ["\\", "\n", "\r", <<0>>]) -> "/"
      true -> value
    end
  end

  def safe_return_to(_value), do: "/"
end
