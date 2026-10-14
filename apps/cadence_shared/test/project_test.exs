defmodule Cadence.Shared.ProjectTest do
  use ExUnit.Case, async: true

  alias Cadence.Shared.Project

  @valid_attrs %{
    name: "Cadence",
    slug: "cadence",
    owner_id: Ecto.UUID.generate()
  }

  describe "changeset/2" do
    test "accepts valid attributes" do
      assert Project.changeset(@valid_attrs).valid?
    end

    test "requires name, slug, and owner_id" do
      changeset = Project.changeset(%{})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset, :name)
      assert "can't be blank" in errors_on(changeset, :slug)
      assert "can't be blank" in errors_on(changeset, :owner_id)
    end

    test "rejects a non-URL-safe slug" do
      changeset = Project.changeset(Map.put(@valid_attrs, :slug, "Not URL Safe!"))

      refute changeset.valid?
      assert errors_on(changeset, :slug) != []
    end

    test "accepts a kebab-case slug" do
      assert Project.changeset(Map.put(@valid_attrs, :slug, "my-project")).valid?
    end

    test "rejects a malformed owner_id" do
      changeset = Project.changeset(Map.put(@valid_attrs, :owner_id, "nope"))

      refute changeset.valid?
      assert errors_on(changeset, :owner_id) != []
    end
  end

  defp errors_on(changeset, field) do
    changeset.errors
    |> Keyword.get_values(field)
    |> Enum.map(fn {message, _opts} -> message end)
  end
end
