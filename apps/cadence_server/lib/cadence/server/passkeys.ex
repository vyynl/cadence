defmodule Cadence.Server.Passkeys do
  @moduledoc """
  Passkey (WebAuthn/FIDO2) ceremonies and credential management (plan §7).

  This module owns the relying-party logic: challenge generation, the
  serializable challenge map kept in the signed cookie session, attestation and
  assertion verification through `Wax`, and user-scoped credential CRUD. It has
  no HTTP or UI code; controllers in G2/G3 map requests to these functions.

  ## Challenge lifecycle

  A challenge is returned as a string-keyed map (bytes base64, type, origin,
  rp_id, issued_at, optional user_id) suitable for the signed Phoenix session.
  One-shot semantics are the caller's responsibility: delete the session key
  *before* calling a `verify_*` function. `consume_challenge/2` validates the
  map (shape, config binding, type, user binding, and the configured lifetime;
  120 s by default) and returns a `Wax.Challenge` for verification.

  ## Sign counter

  WebAuthn only defines clone detection when both the stored and the received
  counters are non-zero: a received counter that does not advance is refused.
  A zero counter is accepted and never lowers the stored value (many synced
  platform passkeys always report zero). `record_use/3` applies the update with
  a compare-and-swap on the old counter, so two concurrent assertions cannot
  both win.
  """

  require Ash.Expr
  require Ash.Query

  alias Cadence.Server.Accounts
  alias Cadence.Server.Accounts.{User, WebAuthnCredential}
  alias Cadence.Server.Passkeys.Config

  @session_key "webauthn_challenge"
  @default_label "Security key"

  @type challenge_map :: %{
          required(String.t()) => String.t() | integer()
        }

  @type reason ::
          :disabled
          | :expired
          | :wrong_type
          | :wrong_origin
          | :wrong_rp_id
          | :invalid_attestation
          | :invalid_assertion
          | :unknown_credential
          | :sign_count_regression
          | :user_verification_failed
          | :invalid_challenge
          | :challenge_user_mismatch
          | :max_credentials
          | :duplicate_credential
          | :invalid_credential
          | :invalid_label
          | :not_found
          | :storage_error

  @doc "The session key used for the in-flight challenge (both ceremonies)."
  def session_key, do: @session_key

  @doc "The effective challenge lifetime in seconds (CAD_WEBAUTHN_TIMEOUT_MS)."
  def challenge_lifetime_seconds, do: seconds(Config.get().timeout_ms)

  @doc """
  Builds registration options for `navigator.credentials.create`.

  Returns `{:ok, %{public_key: options, challenge: challenge_map}}`. The
  challenge map must be stored in the signed session and passed back to
  `verify_registration/3`.

  Options:

    * `:config` — keyword overrides for tests and alternate deployments.
    * `:credentials` — preloaded credential list (avoids a query in tests).
  """
  @spec registration_challenge(User.t(), keyword()) ::
          {:ok, %{public_key: map(), challenge: challenge_map()}} | {:error, reason()}
  def registration_challenge(%User{} = user, opts \\ []) do
    config = Config.get(Keyword.get(opts, :config, []))

    with :ok <- ensure_enabled(config),
         {:ok, credentials} <- credentials_for(user, opts) do
      wax_challenge =
        Wax.new_registration_challenge(
          origin: config.origin,
          rp_id: config.rp_id,
          user_verification: config.user_verification,
          attestation: "none",
          trusted_attestation_types: [:none],
          timeout: seconds(config.timeout_ms)
        )

      challenge =
        challenge_map(wax_challenge, "attestation", user_id(user))

      options = %{
        "rp" => %{"id" => config.rp_id, "name" => config.rp_name},
        "user" => %{
          "id" => Base.url_encode64(user_handle(user), padding: false),
          "name" => to_string(user.email),
          "displayName" => user.name || to_string(user.email)
        },
        "challenge" => Base.url_encode64(wax_challenge.bytes, padding: false),
        "pubKeyCredParams" => [
          %{"type" => "public-key", "alg" => -7},
          %{"type" => "public-key", "alg" => -257}
        ],
        "timeout" => config.timeout_ms,
        "attestation" => "none",
        "authenticatorSelection" => %{
          "residentKey" => "required",
          "requireResidentKey" => true,
          "userVerification" => config.user_verification
        },
        "excludeCredentials" => Enum.map(credentials, &descriptor/1)
      }

      {:ok, %{public_key: options, challenge: challenge}}
    end
  end

  @doc """
  Builds authentication options for `navigator.credentials.get`.

  Discoverable (resident) credentials are the default, so `allowCredentials` is
  empty. Pass `:allow_credentials` as `[{raw_id, cose_key}]` for the
  non-discoverable flow.

  Returns `{:ok, %{public_key: options, challenge: challenge_map}}`.
  """
  @spec authentication_challenge(keyword()) ::
          {:ok, %{public_key: map(), challenge: challenge_map()}} | {:error, reason()}
  def authentication_challenge(opts \\ []) do
    config = Config.get(Keyword.get(opts, :config, []))
    allow_credentials = Keyword.get(opts, :allow_credentials, [])

    with :ok <- ensure_enabled(config) do
      wax_challenge =
        Wax.new_authentication_challenge(
          origin: config.origin,
          rp_id: config.rp_id,
          user_verification: config.user_verification,
          timeout: seconds(config.timeout_ms),
          allow_credentials: allow_credentials
        )

      options = %{
        "challenge" => Base.url_encode64(wax_challenge.bytes, padding: false),
        "timeout" => config.timeout_ms,
        "rpId" => config.rp_id,
        "allowCredentials" => Enum.map(allow_credentials, &descriptor/1),
        "userVerification" => config.user_verification
      }

      {:ok,
       %{
         public_key: options,
         challenge: challenge_map(wax_challenge, "authentication", nil)
       }}
    end
  end

  @doc """
  Validates a session challenge map and rebuilds the `Wax.Challenge`.

  Options: `:type` (`:attestation`/`:authentication`) and `:user_id` (binding
  check for registration). The caller must delete the session key before
  verification; this function does not mutate anything.
  """
  @spec consume_challenge(map(), keyword()) :: {:ok, Wax.Challenge.t()} | {:error, reason()}
  def consume_challenge(challenge, opts \\ []) do
    config = Config.get(Keyword.get(opts, :config, []))

    with {:ok, challenge} <- normalize_challenge(challenge),
         :ok <- check_challenge_config(challenge, config),
         {:ok, type} <- challenge_type(challenge, opts[:type]),
         :ok <- check_user_binding(challenge, opts[:user_id]),
         {:ok, bytes} <- decode_bytes(challenge),
         {:ok, issued_at} <- issued_at(challenge),
         :ok <- check_age(issued_at, config.timeout_ms) do
      {:ok,
       %Wax.Challenge{
         type: type,
         bytes: bytes,
         origin: challenge["origin"],
         rp_id: challenge["rp_id"],
         issued_at: issued_at,
         timeout: seconds(config.timeout_ms),
         user_verification: config.user_verification,
         attestation: "none",
         trusted_attestation_types: [:none],
         allow_credentials: [],
         origin_verify_fun: {Wax, :origins_match?, []}
       }}
    end
  end

  @doc """
  Verifies a registration response and returns the fields needed to store a
  credential. It does not write to the database; call `create_credential/3`
  next.

  `credential_response` is a map with `:attestation_object` (raw CBOR binary),
  `:client_data_json` (raw JSON binary), optional `:credential_id` (raw bytes,
  checked against the authenticator data), and optional `:transports`
  (client-supplied list of strings).
  """
  @spec verify_registration(User.t() | binary(), map(), map()) ::
          {:ok, map()} | {:error, reason()}
  def verify_registration(user, challenge, credential_response) do
    config = Config.get()

    with :ok <- ensure_enabled(config),
         {:ok, wax_challenge} <-
           consume_challenge(challenge, type: :attestation, user_id: user_id(user)),
         {:ok, response} <- parse_registration(credential_response),
         {:ok, {auth_data, {attestation_type, _trust_path, _metadata}}} <-
           run_register(response, wax_challenge),
         :ok <- accept_attestation_type(attestation_type),
         :ok <- require_user_verification(auth_data, config),
         :ok <- match_response_credential_id(response, auth_data),
         {:ok, attested} <- attested_credential_data(auth_data) do
      {:ok,
       %{
         credential_id: attested.credential_id,
         public_key: attested.credential_public_key,
         sign_count: auth_data.sign_count,
         aaguid: Wax.AuthenticatorData.get_aaguid(auth_data),
         attestation_type: "none",
         transports: response.transports
       }}
    end
  end

  @doc """
  Verifies an assertion response and returns the matching credential and the
  received sign count. The caller decides whether to sign the user in; use
  `record_use/3` after a successful session renewal.

  `assertion_response` is a map with `:credential_id` (raw bytes),
  `:authenticator_data` (raw bytes), `:signature` (raw DER bytes),
  `:client_data_json` (raw JSON binary), and optional `:user_handle`.
  """
  @spec verify_authentication(map(), map()) :: {:ok, map()} | {:error, reason()}
  def verify_authentication(challenge, assertion_response) do
    config = Config.get()

    with :ok <- ensure_enabled(config),
         {:ok, wax_challenge} <- consume_challenge(challenge, type: :authentication),
         {:ok, response} <- parse_assertion(assertion_response),
         {:ok, credential} <- fetch_by_raw_id(response.credential_id),
         {:ok, auth_data} <- run_authenticate(response, credential, wax_challenge),
         :ok <- require_user_verification(auth_data, config),
         :ok <- check_sign_count(credential.sign_count, auth_data.sign_count) do
      {:ok,
       %{
         credential: credential,
         user_id: credential.user_id,
         sign_count: auth_data.sign_count,
         user_handle: response.user_handle
       }}
    end
  end

  @doc """
  Stores a verified registration. Enforces the per-user cap and maps a
  duplicate credential id to `:duplicate_credential`.

  `attrs` may override `:label` and `:transports`.
  """
  @spec create_credential(User.t() | binary(), map(), map()) ::
          {:ok, WebAuthnCredential.t()} | {:error, reason()}
  def create_credential(user, registration, attrs \\ %{}) do
    config = Config.get()

    user_id = user_id(user)

    with :ok <- ensure_enabled(config),
         :ok <- validate_registration(registration),
         {:ok, count} <- count_credentials(user_id),
         :ok <- check_cap(count, config.max_credentials),
         :ok <- ensure_unique_credential(registration.credential_id) do
      params = %{
        user_id: user_id,
        credential_id: registration.credential_id,
        public_key: registration.public_key,
        sign_count: Map.get(registration, :sign_count, 0),
        aaguid: Map.get(registration, :aaguid),
        attestation_type: Map.get(registration, :attestation_type, "none"),
        transports: Map.get(attrs, :transports, Map.get(registration, :transports, [])),
        label: Map.get(attrs, :label, @default_label)
      }

      WebAuthnCredential
      |> Ash.Changeset.for_create(:create, params)
      |> Ash.create(domain: Accounts)
      |> case do
        {:ok, credential} -> {:ok, credential}
        {:error, error} -> {:error, map_create_error(error)}
      end
    end
  end

  @doc "Lists a user's credentials, oldest first."
  @spec list(User.t() | binary()) :: {:ok, [WebAuthnCredential.t()]} | {:error, reason()}
  def list(user) do
    uid = user_id(user)

    WebAuthnCredential
    |> Ash.Query.filter(user_id == ^uid)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read(domain: Accounts)
    |> case do
      {:ok, credentials} -> {:ok, credentials}
      {:error, _error} -> {:error, :storage_error}
    end
  end

  @doc """
  Renames a credential owned by `user`. Accepts either `(user, id, label)` or
  `(user, %{id: id, label: label})`.
  """
  @spec rename(User.t() | binary(), map()) :: {:ok, WebAuthnCredential.t()} | {:error, reason()}
  def rename(user, %{id: credential_id, label: label}) do
    rename(user, credential_id, label)
  end

  def rename(user, %{"id" => credential_id, "label" => label}) do
    rename(user, credential_id, label)
  end

  @spec rename(User.t() | binary(), binary(), String.t()) ::
          {:ok, WebAuthnCredential.t()} | {:error, reason()}
  def rename(user, credential_id, label) do
    with {:ok, credential} <- fetch_scoped(user, credential_id) do
      credential
      |> Ash.Changeset.for_update(:rename, %{label: label})
      |> Ash.update(domain: Accounts)
      |> case do
        {:ok, updated} -> {:ok, updated}
        {:error, %Ash.Error.Invalid{}} -> {:error, :invalid_label}
        {:error, _error} -> {:error, :storage_error}
      end
    end
  end

  @doc "Deletes a credential scoped to `user`."
  @spec delete(User.t() | binary(), binary()) :: :ok | {:error, reason()}
  def delete(user, credential_id) do
    with {:ok, credential} <- fetch_scoped(user, credential_id) do
      case Ash.destroy(credential, domain: Accounts) do
        :ok -> :ok
        {:ok, _credential} -> :ok
        {:error, _error} -> {:error, :storage_error}
      end
    end
  end

  @doc """
  Records a successful assertion for a credential owned by `user`.

  Applies the sign-count rule and a compare-and-swap on the previous counter.
  `new_sign_count` may be zero; the stored value then stays at its previous
  maximum.
  """
  @spec record_use(User.t() | binary(), binary(), non_neg_integer()) ::
          {:ok, WebAuthnCredential.t()} | {:error, reason()}
  def record_use(user, credential_id, new_sign_count) when is_integer(new_sign_count) do
    with :ok <- validate_sign_count(new_sign_count),
         {:ok, credential} <- fetch_scoped(user, credential_id),
         :ok <- check_sign_count(credential.sign_count, new_sign_count) do
      old_sign_count = credential.sign_count
      next_sign_count = max(old_sign_count, new_sign_count)

      credential
      |> Ash.Changeset.for_update(:record_use, %{
        sign_count: next_sign_count,
        last_used_at: DateTime.utc_now()
      })
      |> Ash.Changeset.filter(Ash.Expr.expr(sign_count == ^old_sign_count))
      |> Ash.update(domain: Accounts)
      |> case do
        {:ok, updated} ->
          {:ok, updated}

        {:error, %Ash.Error.Invalid{errors: errors}} ->
          if Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)) do
            {:error, :sign_count_regression}
          else
            {:error, :storage_error}
          end

        {:error, _error} ->
          {:error, :storage_error}
      end
    end
  end

  @doc false
  # WebAuthn clone-detection rule: reject only when both counters are non-zero
  # and the received counter did not advance. Zero is accepted by design.
  def sign_count_regression?(stored, received) when stored > 0 and received > 0 do
    received <= stored
  end

  def sign_count_regression?(_stored, _received), do: false

  # -- challenge helpers -----------------------------------------------------

  defp challenge_map(%Wax.Challenge{} = challenge, type, user_id) do
    %{
      "bytes" => Base.encode64(challenge.bytes),
      "type" => type,
      "origin" => challenge.origin,
      "rp_id" => challenge.rp_id,
      "issued_at" => challenge.issued_at
    }
    |> maybe_put_user_id(user_id)
  end

  defp maybe_put_user_id(map, nil), do: map
  defp maybe_put_user_id(map, user_id), do: Map.put(map, "user_id", to_string(user_id))

  defp normalize_challenge(challenge) when is_map(challenge) do
    required = ["bytes", "type", "origin", "rp_id", "issued_at"]

    if Enum.all?(required, &Map.has_key?(challenge, &1)) and
         is_binary(challenge["origin"]) and is_binary(challenge["rp_id"]) and
         is_integer(challenge["issued_at"]) do
      {:ok, challenge}
    else
      {:error, :invalid_challenge}
    end
  end

  defp normalize_challenge(_challenge), do: {:error, :invalid_challenge}

  defp challenge_type(challenge, nil) do
    case challenge["type"] do
      "attestation" -> {:ok, :attestation}
      "authentication" -> {:ok, :authentication}
      _ -> {:error, :invalid_challenge}
    end
  end

  defp challenge_type(challenge, expected) do
    case challenge_type(challenge, nil) do
      {:ok, ^expected} -> {:ok, expected}
      {:ok, _other} -> {:error, :wrong_type}
      error -> error
    end
  end

  defp check_challenge_config(challenge, config) do
    cond do
      challenge["rp_id"] != config.rp_id -> {:error, :wrong_rp_id}
      challenge["origin"] != config.origin -> {:error, :wrong_origin}
      true -> :ok
    end
  end

  defp check_user_binding(_challenge, nil), do: :ok

  defp check_user_binding(challenge, %User{id: id}), do: check_user_binding(challenge, id)

  defp check_user_binding(challenge, expected_user_id) do
    if challenge["user_id"] == to_string(expected_user_id) do
      :ok
    else
      {:error, :challenge_user_mismatch}
    end
  end

  defp decode_bytes(challenge) do
    case Base.decode64(challenge["bytes"]) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_challenge}
    end
  end

  defp issued_at(challenge), do: {:ok, challenge["issued_at"]}

  defp check_age(issued_at, timeout_ms) do
    age_ms = (System.system_time(:second) - issued_at) * 1000

    cond do
      age_ms < 0 -> {:error, :invalid_challenge}
      age_ms >= timeout_ms -> {:error, :expired}
      true -> :ok
    end
  end

  defp seconds(timeout_ms), do: max(div(timeout_ms, 1000), 1)

  # -- verification helpers --------------------------------------------------

  defp parse_registration(response) when is_map(response) do
    attestation_object = Map.get(response, :attestation_object)
    client_data_json = Map.get(response, :client_data_json)
    credential_id = Map.get(response, :credential_id)
    transports = Map.get(response, :transports, [])

    cond do
      not is_binary(attestation_object) ->
        {:error, :invalid_attestation}

      not is_binary(client_data_json) ->
        {:error, :invalid_attestation}

      not is_nil(credential_id) and not is_binary(credential_id) ->
        {:error, :invalid_attestation}

      not is_list(transports) ->
        {:error, :invalid_attestation}

      true ->
        {:ok,
         %{
           attestation_object: attestation_object,
           client_data_json: client_data_json,
           credential_id: credential_id,
           transports: transports
         }}
    end
  end

  defp parse_registration(_response), do: {:error, :invalid_attestation}

  defp parse_assertion(response) when is_map(response) do
    credential_id = Map.get(response, :credential_id)
    authenticator_data = Map.get(response, :authenticator_data)
    signature = Map.get(response, :signature)
    client_data_json = Map.get(response, :client_data_json)

    if is_binary(credential_id) and is_binary(authenticator_data) and is_binary(signature) and
         is_binary(client_data_json) do
      {:ok,
       %{
         credential_id: credential_id,
         authenticator_data: authenticator_data,
         signature: signature,
         client_data_json: client_data_json,
         user_handle: Map.get(response, :user_handle)
       }}
    else
      {:error, :invalid_assertion}
    end
  end

  defp parse_assertion(_response), do: {:error, :invalid_assertion}

  defp run_register(response, wax_challenge) do
    case Wax.register(response.attestation_object, response.client_data_json, wax_challenge) do
      {:ok, _result} = ok -> ok
      {:error, error} -> {:error, map_wax_error(error, :invalid_attestation)}
    end
  rescue
    # Wax raises on a handful of malformed browser inputs (bad base64, a
    # non-map attestation object). Anything unexpected still propagates.
    _error in [ArgumentError, MatchError, FunctionClauseError] -> {:error, :invalid_attestation}
  end

  defp run_authenticate(response, credential, wax_challenge) do
    case Wax.authenticate(
           response.credential_id,
           response.authenticator_data,
           response.signature,
           response.client_data_json,
           wax_challenge,
           [{response.credential_id, credential.public_key}]
         ) do
      {:ok, auth_data} -> {:ok, auth_data}
      {:error, error} -> {:error, map_wax_error(error, :invalid_assertion)}
    end
  rescue
    _error in [ArgumentError, MatchError, FunctionClauseError] -> {:error, :invalid_assertion}
  end

  defp accept_attestation_type(:none), do: :ok
  defp accept_attestation_type(_type), do: {:error, :invalid_attestation}

  defp attested_credential_data(%{attested_credential_data: %Wax.AttestedCredentialData{} = data}) do
    if is_map(data.credential_public_key) and is_binary(data.credential_id) do
      {:ok, data}
    else
      {:error, :invalid_attestation}
    end
  end

  defp attested_credential_data(_auth_data), do: {:error, :invalid_attestation}

  defp require_user_verification(auth_data, %{user_verification: "required"}) do
    if auth_data.flag_user_verified == true, do: :ok, else: {:error, :user_verification_failed}
  end

  defp require_user_verification(_auth_data, _config), do: :ok

  defp match_response_credential_id(%{credential_id: nil}, _auth_data), do: :ok

  defp match_response_credential_id(%{credential_id: credential_id}, auth_data) do
    if auth_data.attested_credential_data.credential_id == credential_id do
      :ok
    else
      {:error, :invalid_attestation}
    end
  end

  defp check_sign_count(stored, received) when is_integer(received) do
    if sign_count_regression?(stored, received) do
      {:error, :sign_count_regression}
    else
      :ok
    end
  end

  defp validate_sign_count(value) when value >= 0, do: :ok
  defp validate_sign_count(_value), do: {:error, :invalid_assertion}

  defp map_wax_error(%Wax.ExpiredChallengeError{}, _fallback), do: :expired

  defp map_wax_error(%Wax.InvalidClientDataError{reason: :origin_mismatch}, _fallback),
    do: :wrong_origin

  defp map_wax_error(%Wax.InvalidClientDataError{reason: :rp_id_mismatch}, _fallback),
    do: :wrong_rp_id

  defp map_wax_error(%Wax.InvalidClientDataError{reason: :user_not_verified}, _fallback),
    do: :user_verification_failed

  defp map_wax_error(%Wax.InvalidClientDataError{reason: :flag_user_present_not_set}, fallback),
    do: fallback

  defp map_wax_error(%Wax.InvalidClientDataError{reason: reason}, fallback)
       when reason in [:create_type_expected, :get_type_expected],
       do: fallback

  defp map_wax_error(%Wax.InvalidClientDataError{}, fallback), do: fallback
  defp map_wax_error(%Wax.InvalidSignatureError{}, fallback), do: fallback
  defp map_wax_error(%Wax.InvalidCBORError{}, fallback), do: fallback
  defp map_wax_error(%Wax.InvalidAuthenticatorDataError{}, fallback), do: fallback
  defp map_wax_error(%Wax.UnsupportedAttestationFormatError{}, fallback), do: fallback
  defp map_wax_error(%Wax.UntrustedAttestationTypeError{}, fallback), do: fallback
  defp map_wax_error(%Wax.AttestationVerificationError{}, fallback), do: fallback
  defp map_wax_error(%Wax.UnsupportedSignatureAlgorithmError{}, fallback), do: fallback
  defp map_wax_error(_error, fallback), do: fallback

  # -- credential storage ----------------------------------------------------

  defp fetch_by_raw_id(credential_id) do
    WebAuthnCredential
    |> Ash.Query.filter(credential_id == ^credential_id)
    |> Ash.read_one(domain: Accounts)
    |> case do
      {:ok, %WebAuthnCredential{} = credential} -> {:ok, credential}
      {:ok, nil} -> {:error, :unknown_credential}
      {:error, _error} -> {:error, :storage_error}
    end
  end

  defp fetch_scoped(user, credential_id) do
    uid = user_id(user)

    WebAuthnCredential
    |> Ash.Query.filter(user_id == ^uid and credential_id == ^credential_id)
    |> Ash.read_one(domain: Accounts)
    |> case do
      {:ok, %WebAuthnCredential{} = credential} -> {:ok, credential}
      {:ok, nil} -> {:error, :not_found}
      {:error, _error} -> {:error, :storage_error}
    end
  end

  defp count_credentials(user_id) do
    WebAuthnCredential
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.count(domain: Accounts)
    |> case do
      {:ok, count} -> {:ok, count}
      {:error, _error} -> {:error, :storage_error}
    end
  end

  defp ensure_unique_credential(credential_id) do
    case fetch_by_raw_id(credential_id) do
      {:ok, _credential} -> {:error, :duplicate_credential}
      {:error, :unknown_credential} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_cap(count, max) when count >= max, do: {:error, :max_credentials}
  defp check_cap(_count, _max), do: :ok

  defp validate_registration(registration) when is_map(registration) do
    required = [:credential_id, :public_key]

    if Enum.all?(required, &Map.has_key?(registration, &1)) do
      :ok
    else
      {:error, :invalid_credential}
    end
  end

  defp validate_registration(_registration), do: {:error, :invalid_credential}

  defp map_create_error(%Ash.Error.Invalid{errors: errors}) do
    if Enum.any?(errors, &duplicate_error?/1) do
      :duplicate_credential
    else
      :invalid_credential
    end
  end

  defp map_create_error(_error), do: :storage_error

  defp duplicate_error?(%Ash.Error.Changes.InvalidAttribute{
         field: :credential_id,
         message: message
       }) do
    is_binary(message) and String.contains?(message, "already been taken")
  end

  defp duplicate_error?(_error), do: false

  defp credentials_for(user, opts) do
    case Keyword.fetch(opts, :credentials) do
      {:ok, credentials} -> {:ok, credentials}
      :error -> list(user)
    end
  end

  defp descriptor({credential_id, _cose_key}) do
    %{"type" => "public-key", "id" => Base.url_encode64(credential_id, padding: false)}
  end

  defp descriptor(%WebAuthnCredential{} = credential) do
    %{
      "type" => "public-key",
      "id" => Base.url_encode64(credential.credential_id, padding: false)
    }
    |> maybe_put_transports(credential.transports)
  end

  defp maybe_put_transports(map, transports) when transports in [nil, []], do: map
  defp maybe_put_transports(map, transports), do: Map.put(map, "transports", transports)

  defp user_handle(%User{id: id}) do
    secret =
      Application.get_env(:cadence_server, :token_signing_secret) ||
        raise "missing token_signing_secret"

    :crypto.mac(:hmac, :sha256, secret, id)
    |> binary_part(0, 32)
  end

  defp user_id(%User{id: id}), do: id
  defp user_id(id) when is_binary(id) and byte_size(id) > 0, do: id

  defp ensure_enabled(%Config{enabled: true}), do: :ok
  defp ensure_enabled(_config), do: {:error, :disabled}
end
