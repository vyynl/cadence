defmodule Cadence.Server.Accounts.CoseKeyTest do
  use ExUnit.Case, async: true

  alias Cadence.Server.Accounts.CoseKey

  @key %{
    1 => 2,
    3 => -7,
    -1 => 1,
    -2 => :binary.copy(<<7>>, 32),
    -3 => :binary.copy(<<9>>, 32)
  }

  test "round-trips a map through CBOR storage" do
    assert {:ok, encoded} = Ash.Type.dump_to_native(CoseKey, @key, [])
    assert is_binary(encoded)
    assert {:ok, @key} = Ash.Type.cast_stored(CoseKey, encoded, [])
  end

  test "accepts a map at the input boundary" do
    assert {:ok, @key} = Ash.Type.cast_input(CoseKey, @key, [])
    assert {:ok, nil} = Ash.Type.cast_input(CoseKey, nil, [])
  end

  test "rejects a non-map input with a clear error" do
    assert {:error, error} = Ash.Type.cast_input(CoseKey, "not-a-key", [])
    assert error[:message] =~ "COSE key map"
  end

  test "rejects non-CBOR bytes" do
    # 0xFF is the indefinite-length break marker and is invalid on its own.
    assert {:error, error} = Ash.Type.cast_stored(CoseKey, <<0xFF>>, [])
    assert error[:message] =~ "not CBOR"
  end

  test "rejects CBOR that is not a map" do
    encoded = CBOR.encode(["not", "a", "key"])
    assert {:error, error} = Ash.Type.cast_stored(CoseKey, encoded, [])
    assert error[:message] =~ "not a map"
  end

  test "rejects CBOR with trailing bytes" do
    encoded = CBOR.encode(@key) <> <<0>>
    assert {:error, error} = Ash.Type.cast_stored(CoseKey, encoded, [])
    assert error[:message] =~ "trailing bytes"
  end

  test "caps stored keys at 256 KiB" do
    oversized = :binary.copy(<<0>>, 262_145)
    assert {:error, error} = Ash.Type.cast_stored(CoseKey, oversized, [])
    assert error[:message] =~ "decode cap"
  end

  test "caps encoded keys at 256 KiB" do
    # A CBOR map with one huge binary value exceeds the cap when encoded.
    oversized = %{1 => 2, 2 => :binary.copy(<<0>>, 262_144)}
    assert {:error, error} = Ash.Type.dump_to_native(CoseKey, oversized, [])
    assert error[:message] =~ "encode cap"
  end
end
