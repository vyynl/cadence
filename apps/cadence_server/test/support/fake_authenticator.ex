defmodule Cadence.Server.FakeAuthenticator do
  @moduledoc """
  A small software WebAuthn authenticator for tests (plan §10.2).

  Uses `:crypto` directly: a P-256 key pair, a CBOR COSE key, `authData` with
  the RP ID hash and flags, a `fmt: "none"` attestation object, and an ES256
  assertion signature over `authData || SHA256(clientDataJSON)`.

  Every field that verification cares about can be overridden so tests can
  produce honest tampering cases (wrong origin, wrong RP ID, missing UV,
  stale counters, bad signatures) without hand-writing CBOR or DER.
  """

  import Bitwise

  @flags_up 0x01
  @flags_uv 0x04
  @flags_at 0x40

  defstruct [
    :private_key,
    :public_key,
    :cose_key,
    :credential_id,
    :aaguid,
    :sign_count,
    :transports
  ]

  @type t :: %__MODULE__{}

  @doc """
  Generates a fresh authenticator. Options: `:credential_id`, `:aaguid`,
  `:sign_count`, `:transports`.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    {public_key, private_key} = :crypto.generate_key(:ecdh, :secp256r1)
    <<4, x::binary-size(32), y::binary-size(32)>> = public_key

    %__MODULE__{
      private_key: private_key,
      public_key: public_key,
      cose_key: %{1 => 2, 3 => -7, -1 => 1, -2 => x, -3 => y},
      credential_id: Keyword.get(opts, :credential_id, :crypto.strong_rand_bytes(32)),
      aaguid: Keyword.get(opts, :aaguid, <<1::128>>),
      sign_count: Keyword.get(opts, :sign_count, 0),
      transports: Keyword.get(opts, :transports, ["usb"])
    }
  end

  @doc "Builds a registration response for a challenge map."
  @spec attest(t(), map(), keyword()) :: map()
  def attest(%__MODULE__{} = authenticator, challenge, opts \\ []) do
    origin = Keyword.get(opts, :origin, challenge["origin"])
    rp_id = Keyword.get(opts, :rp_id, challenge["rp_id"])
    challenge_bytes = challenge_bytes(challenge, opts)
    credential_id = Keyword.get(opts, :credential_id, authenticator.credential_id)
    aaguid = Keyword.get(opts, :aaguid, authenticator.aaguid)
    sign_count = Keyword.get(opts, :sign_count, authenticator.sign_count)
    flags = Keyword.get(opts, :flags, @flags_up ||| @flags_uv ||| @flags_at)

    client_data_json = client_data_json("webauthn.create", challenge_bytes, origin)

    auth_data =
      auth_data(rp_id, flags, sign_count, aaguid, credential_id, authenticator.cose_key)

    attestation_object =
      CBOR.encode(%{"fmt" => "none", "attStmt" => %{}, "authData" => auth_data})

    %{
      attestation_object: attestation_object,
      client_data_json: client_data_json,
      credential_id: credential_id,
      transports: Keyword.get(opts, :transports, authenticator.transports)
    }
  end

  @doc "Builds an assertion response for a challenge map."
  @spec assert(t(), map(), keyword()) :: map()
  def assert(%__MODULE__{} = authenticator, challenge, opts \\ []) do
    origin = Keyword.get(opts, :origin, challenge["origin"])
    rp_id = Keyword.get(opts, :rp_id, challenge["rp_id"])
    challenge_bytes = challenge_bytes(challenge, opts)
    credential_id = Keyword.get(opts, :credential_id, authenticator.credential_id)
    sign_count = Keyword.get(opts, :sign_count, authenticator.sign_count)
    flags = Keyword.get(opts, :flags, @flags_up ||| @flags_uv)

    client_data_json = client_data_json("webauthn.get", challenge_bytes, origin)
    auth_data = auth_data(rp_id, flags, sign_count, nil, nil, nil)

    signature =
      :crypto.sign(
        :ecdsa,
        :sha256,
        auth_data <> :crypto.hash(:sha256, client_data_json),
        [authenticator.private_key, :secp256r1]
      )

    signature =
      if Keyword.get(opts, :tamper_signature, false) do
        <<first, rest::binary>> = signature
        <<Bitwise.bxor(first, 0x01), rest::binary>>
      else
        signature
      end

    %{
      credential_id: credential_id,
      authenticator_data: auth_data,
      signature: signature,
      client_data_json: client_data_json,
      user_handle: Keyword.get(opts, :user_handle)
    }
  end

  @doc "Builds `authData`; exposed for negative tests that need a raw override."
  @spec auth_data(
          String.t(),
          byte(),
          non_neg_integer(),
          binary() | nil,
          binary() | nil,
          map() | nil
        ) ::
          binary()
  def auth_data(rp_id, flags, sign_count, aaguid, credential_id, cose_key) do
    prefix = :crypto.hash(:sha256, rp_id) <> <<flags::8, sign_count::32>>

    if Bitwise.band(flags, @flags_at) == @flags_at do
      prefix <>
        aaguid <>
        <<byte_size(credential_id)::16>> <>
        credential_id <>
        CBOR.encode(cose_key)
    else
      prefix
    end
  end

  defp challenge_bytes(challenge, opts) do
    case Keyword.fetch(opts, :challenge_bytes) do
      {:ok, bytes} -> bytes
      :error -> Base.decode64!(challenge["bytes"])
    end
  end

  defp client_data_json(type, challenge_bytes, origin) do
    Jason.encode!(%{
      "type" => type,
      "challenge" => Base.url_encode64(challenge_bytes, padding: false),
      "origin" => origin
    })
  end
end
