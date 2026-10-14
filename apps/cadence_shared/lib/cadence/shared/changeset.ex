defmodule Cadence.Shared.Changeset do
  @moduledoc """
  Shared `Ecto.Changeset` validators for the Cadence schemas.

  Extracted so `Node`, `Project`, and `Membership` share one UUID check rather
  than each carrying a near-identical private copy.
  """

  import Ecto.Changeset

  @doc """
  Validates that one or more fields hold a UUID string.

  Pass a single field or a list. `nil` is ignored (Ecto only runs validators on
  present changes), so required fields should still use `validate_required/2`.
  """
  @spec validate_uuid(Ecto.Changeset.t(), atom() | [atom()]) :: Ecto.Changeset.t()
  def validate_uuid(changeset, field_or_fields) do
    field_or_fields
    |> List.wrap()
    |> Enum.reduce(changeset, fn field, acc ->
      validate_change(acc, field, fn ^field, value ->
        if valid_uuid?(value) do
          []
        else
          [{field, "is not a valid UUID"}]
        end
      end)
    end)
  end

  defp valid_uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp valid_uuid?(_value), do: false
end
