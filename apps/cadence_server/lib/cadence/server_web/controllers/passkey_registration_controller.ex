defmodule Cadence.ServerWeb.PasskeyRegistrationController do
  @moduledoc """
  Security-key / passkey registration (plan §7.5).

  `new/2` mints a registration challenge, stores it in the signed session, and
  renders the browser options. `create/2` consumes that challenge exactly once
  (the session key is deleted *before* verification), verifies the attestation
  through `Cadence.Server.Passkeys`, and stores the credential with the
  user-supplied label and client transports.

  The POST is routed with `log: false` and every failure is mapped from a reason
  atom, so credential material never reaches logs or flash messages.
  """

  use Cadence.ServerWeb, :controller

  alias Cadence.Server.Passkeys
  alias Cadence.Server.Passkeys.Config
  alias Cadence.ServerWeb.PasskeyHelpers

  def new(conn, _params) do
    PasskeyHelpers.with_user(conn, fn conn, user ->
      PasskeyHelpers.with_sudo(conn, fn conn ->
        case Passkeys.registration_challenge(user) do
          {:ok, %{public_key: options, challenge: challenge}} ->
            conn
            |> put_session(Passkeys.session_key(), challenge)
            |> render(:new,
              page_title: "Add a security key",
              page_description: "Register a security key or passkey with your Cadence account.",
              options_json: Jason.encode!(options)
            )

          {:error, reason} ->
            conn
            |> put_flash(:error, error_copy(reason))
            |> redirect(to: "/account/security")
        end
      end)
    end)
  end

  def create(conn, params) do
    PasskeyHelpers.with_user(conn, fn conn, user ->
      PasskeyHelpers.with_sudo(conn, fn conn ->
        # One ceremony per challenge: remove it before any verification work.
        challenge = get_session(conn, Passkeys.session_key())
        conn = delete_session(conn, Passkeys.session_key())

        with {:ok, response} <- decode_registration(params),
             {:ok, registration} <- Passkeys.verify_registration(user, challenge, response),
             {:ok, credential} <-
               Passkeys.create_credential(user, registration, credential_attrs(params)) do
          PasskeyHelpers.respond(
            conn,
            :ok,
            "Security key added: #{credential.label}.",
            "/account/security"
          )
        else
          {:error, :disabled} ->
            PasskeyHelpers.not_found(conn)

          {:error, reason} ->
            PasskeyHelpers.respond(
              conn,
              :error,
              error_copy(reason),
              "/account/security/keys/new"
            )
        end
      end)
    end)
  end

  # -- request decoding ------------------------------------------------------

  defp decode_registration(params) when is_map(params) do
    response = Map.get(params, "response", %{})

    with {:ok, attestation_object} <-
           decode_b64(Map.get(response, "attestationObject")),
         {:ok, client_data_json} <- decode_b64(Map.get(response, "clientDataJSON")),
         {:ok, credential_id} <- decode_b64(Map.get(params, "rawId")) do
      {:ok,
       %{
         attestation_object: attestation_object,
         client_data_json: client_data_json,
         credential_id: credential_id,
         transports: transports(params)
       }}
    else
      _ -> {:error, :invalid_attestation}
    end
  end

  defp decode_registration(_params), do: {:error, :invalid_attestation}

  defp decode_b64(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> :error
    end
  end

  defp decode_b64(_value), do: :error

  defp transports(params) do
    case Map.get(params, "transports") do
      values when is_list(values) -> Enum.filter(values, &is_binary/1)
      _other -> []
    end
  end

  defp credential_attrs(params) do
    %{
      label: label(params),
      transports: transports(params)
    }
  end

  defp label(params) do
    case Map.get(params, "label") do
      value when is_binary(value) -> String.trim(value)
      _other -> ""
    end
  end

  # -- user-facing copy ------------------------------------------------------

  defp error_copy(:duplicate_credential),
    do: "This security key or passkey is already registered on your account."

  defp error_copy(:max_credentials),
    do:
      "You have reached the maximum number of security keys " <>
        "(#{Config.get().max_credentials}). Remove one before adding another."

  defp error_copy(:invalid_label), do: "Enter a name between 1 and 60 characters."

  defp error_copy(:expired),
    do: "Your registration attempt expired. Start again."

  defp error_copy(:invalid_challenge),
    do: "Your registration attempt expired. Start again."

  defp error_copy(:wrong_origin),
    do: "The browser reported a different site address. Contact your administrator."

  defp error_copy(:wrong_rp_id),
    do: "The browser reported a different site address. Contact your administrator."

  defp error_copy(:user_verification_failed),
    do:
      "Your security key did not verify you. Set a PIN (or enroll a fingerprint) on the key and try again."

  defp error_copy(:invalid_attestation),
    do: "That security key could not be added. Try again with a FIDO2 security key or a passkey."

  defp error_copy(:invalid_credential),
    do: "That security key could not be added. Try again with a FIDO2 security key or a passkey."

  defp error_copy(_reason),
    do: "That security key could not be added. Try again or use another sign-in method."
end
