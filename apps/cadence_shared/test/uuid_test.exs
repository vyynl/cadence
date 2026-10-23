defmodule Cadence.Shared.UUIDTest do
  use ExUnit.Case, async: true

  alias Cadence.Shared.UUID

  test "casts valid UUID strings" do
    value = Ecto.UUID.generate()
    assert UUID.cast(value) == {:ok, value}
    assert UUID.valid?(value)
  end

  test "rejects malformed and non-string values" do
    assert UUID.cast("nope") == :error
    assert UUID.cast(nil) == :error
    assert UUID.cast(123) == :error
    refute UUID.valid?("nope")
  end
end
