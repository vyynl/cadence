defmodule Cadence.Server.Security.SecretBox do
  @moduledoc """
  Small AES-256-GCM envelope for values that must not be readable from a
  database dump — currently the TOTP shared secret (spec §7.4).

  The key comes from `CAD_TOTP_KEY` when set (32 raw bytes, base64, or a
  passphrase that is hashed). Otherwise it is derived from the endpoint's
  `secret_key_base`, which is already required to be secret in production.

  Rotating the source key makes every stored TOTP secret undecryptable; the
  operator recovery path is `mix cadence.user --reset-totp`.
  """

  @aad "cadence:totp-secret:v1"
  @iv_bytes 12
  @tag_bytes 16

  @doc "Encrypts a binary and returns a URL-safe, unpadded string."
  @spec encrypt(binary()) :: String.t()
  def encrypt(plaintext) when is_binary(plaintext) do
    iv = :crypto.strong_rand_bytes(@iv_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, plaintext, @aad, true)

    Base.url_encode64(iv <> tag <> ciphertext, padding: false)
  end

  @doc "Decrypts a value produced by `encrypt/1`."
  @spec decrypt(binary()) :: {:ok, binary()} | :error
  def decrypt(encoded) when is_binary(encoded) do
    with {:ok, <<iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>>} <-
           Base.url_decode64(encoded, padding: false),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, ciphertext, @aad, tag, false) do
      {:ok, plaintext}
    else
      _ -> :error
    end
  end

  def decrypt(_encoded), do: :error

  defp key do
    case Application.get_env(:cadence_server, :totp_key) do
      nil -> derive_from_secret_key_base()
      "" -> derive_from_secret_key_base()
      key when is_binary(key) and byte_size(key) == 32 -> key
      encoded when is_binary(encoded) -> decode_or_hash(encoded)
      _ -> raise "invalid :totp_key configuration"
    end
  end

  defp decode_or_hash(encoded) do
    case Base.decode64(encoded) do
      {:ok, key} when byte_size(key) == 32 -> key
      _ -> :crypto.hash(:sha256, encoded)
    end
  end

  defp derive_from_secret_key_base do
    secret_key_base =
      Application.get_env(:cadence_server, Cadence.ServerWeb.Endpoint)[:secret_key_base] ||
        raise "secret_key_base is required to derive the TOTP encryption key"

    :crypto.hash(:sha256, "cadence:totp:" <> secret_key_base)
  end
end
