defmodule Cadence.Server.Security.SecretBoxTest do
  use ExUnit.Case, async: false

  alias Cadence.Server.Security.SecretBox

  setup do
    original = Application.get_env(:cadence_server, :totp_key)
    on_exit(fn -> restore(original) end)
    :ok
  end

  test "round-trips a plaintext and uses a fresh IV per encryption" do
    first = SecretBox.encrypt("my totp secret")
    second = SecretBox.encrypt("my totp secret")

    refute first == second
    assert {:ok, "my totp secret"} = SecretBox.decrypt(first)
    assert {:ok, "my totp secret"} = SecretBox.decrypt(second)
  end

  test "tampering fails closed" do
    encoded = SecretBox.encrypt("my totp secret")
    <<first, rest::binary>> = encoded
    tampered = <<bump(first)>> <> rest

    assert SecretBox.decrypt(tampered) == :error
    assert SecretBox.decrypt("not-base64") == :error
    assert SecretBox.decrypt(nil) == :error
  end

  test "accepts a 32-byte raw key" do
    Application.put_env(:cadence_server, :totp_key, :crypto.strong_rand_bytes(32))
    encoded = SecretBox.encrypt("raw key secret")
    assert {:ok, "raw key secret"} = SecretBox.decrypt(encoded)
  end

  test "accepts a base64 key with 32 decoded bytes" do
    Application.put_env(:cadence_server, :totp_key, Base.encode64(:crypto.strong_rand_bytes(32)))
    encoded = SecretBox.encrypt("base64 key secret")
    assert {:ok, "base64 key secret"} = SecretBox.decrypt(encoded)
  end

  test "hashes a passphrase key" do
    Application.put_env(:cadence_server, :totp_key, "a long passphrase")
    encoded = SecretBox.encrypt("passphrase secret")
    assert {:ok, "passphrase secret"} = SecretBox.decrypt(encoded)
  end

  test "falls back to a key derived from secret_key_base" do
    Application.put_env(:cadence_server, :totp_key, nil)
    encoded = SecretBox.encrypt("derived secret")
    assert {:ok, "derived secret"} = SecretBox.decrypt(encoded)
  end

  defp bump(byte) when byte == 255, do: 0
  defp bump(byte), do: byte + 1

  defp restore(nil), do: Application.delete_env(:cadence_server, :totp_key)
  defp restore(value), do: Application.put_env(:cadence_server, :totp_key, value)
end
