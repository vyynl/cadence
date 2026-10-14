defmodule Cadence.Shared.ChangesetTest do
  use ExUnit.Case, async: true

  alias Cadence.Shared.Changeset, as: SharedChangeset
  alias Cadence.Shared.Project

  # A changeset over the Project struct with the given raw changes applied, so
  # `validate_uuid/3` actually sees them as changes.
  defp base(changes) do
    Ecto.Changeset.change(%Project{name: "x", slug: "x"}, changes)
  end

  test "accepts a valid UUID" do
    changeset =
      base(%{owner_id: Ecto.UUID.generate()}) |> SharedChangeset.validate_uuid(:owner_id)

    assert changeset.valid?
  end

  test "rejects a malformed UUID" do
    changeset = base(%{owner_id: "nope"}) |> SharedChangeset.validate_uuid(:owner_id)
    refute changeset.valid?
    assert errors_on(changeset, :owner_id) != []
  end

  test "ignores nil (required-ness is validate_required's job)" do
    changeset =
      base(%{})
      |> Ecto.Changeset.force_change(:owner_id, nil)
      |> SharedChangeset.validate_uuid(:owner_id)

    assert changeset.valid?
    assert changeset.errors == []
  end

  test "validates a list of fields" do
    attrs = %{owner_id: Ecto.UUID.generate(), id: Ecto.UUID.generate()}
    changeset = base(attrs) |> SharedChangeset.validate_uuid([:owner_id, :id])
    assert changeset.valid?
  end

  defp errors_on(changeset, field) do
    changeset.errors
    |> Keyword.get_values(field)
    |> Enum.map(fn {message, _opts} -> message end)
  end
end
