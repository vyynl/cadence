defmodule Cadence.Server.Accounts.CoseKey do
  @moduledoc """
  Ash type for a WebAuthn COSE public key (spec §7.4, plan §7.2).

  The runtime value is the map representation used by `Wax.CoseKey`
  (`%{1 => 2, 3 => -7, -1 => 1, -2 => x, -3 => y}` for ES256). The database
  value is CBOR, which is what `Wax.register/3` returns and what a future
  AshAuthentication 5 WebAuthn strategy stores.

  Stored keys are capped at 256 KiB before decoding so a corrupt or hostile
  database value cannot force an unbounded CBOR allocation. Malformed values
  are rejected with a clear message rather than crashing the data layer.
  """

  use Ash.Type

  @max_bytes 262_144
  @required_kty 1

  @type t :: %{required(integer()) => integer() | binary()}

  @impl Ash.Type
  def storage_type(_constraints), do: :binary

  @impl Ash.Type
  def cast_input(nil, _constraints), do: {:ok, nil}

  def cast_input(%{} = value, _constraints), do: validate_key(value)

  def cast_input(_value, _constraints) do
    {:error, message: "must be a COSE key map"}
  end

  @impl Ash.Type
  def cast_stored(nil, _constraints), do: {:ok, nil}

  def cast_stored(binary, _constraints) when is_binary(binary) do
    cond do
      byte_size(binary) > @max_bytes ->
        {:error, message: "COSE key exceeds the #{@max_bytes}-byte decode cap"}

      true ->
        decode(binary)
    end
  end

  def cast_stored(_value, _constraints) do
    {:error, message: "stored COSE key must be CBOR-encoded bytes"}
  end

  @impl Ash.Type
  def dump_to_native(nil, _constraints), do: {:ok, nil}

  def dump_to_native(%{} = value, _constraints) do
    with {:ok, value} <- validate_key(value) do
      encoded = CBOR.encode(value)

      if byte_size(encoded) > @max_bytes do
        {:error, message: "COSE key exceeds the #{@max_bytes}-byte encode cap"}
      else
        {:ok, encoded}
      end
    end
  end

  def dump_to_native(_value, _constraints) do
    {:error, message: "must be a COSE key map"}
  end

  defp decode(binary) do
    case CBOR.decode(binary) do
      {:ok, value, ""} -> validate_key(value)
      {:ok, _value, _rest} -> {:error, message: "invalid COSE key: trailing bytes"}
      {:error, _reason} -> {:error, message: "invalid COSE key: not CBOR"}
    end
  rescue
    _ -> {:error, message: "invalid COSE key: not CBOR"}
  end

  defp validate_key(%{} = value) do
    if is_integer(Map.get(value, @required_kty)) do
      {:ok, value}
    else
      {:error, message: "invalid COSE key: missing integer kty"}
    end
  end

  defp validate_key(_value), do: {:error, message: "invalid COSE key: not a map"}
end
