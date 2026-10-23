defmodule Cadence.Shared.MembershipTest do
  use ExUnit.Case, async: true

  alias Cadence.Shared.Membership

  @valid_attrs %{
    user_id: Ecto.UUID.generate(),
    project_id: Ecto.UUID.generate(),
    role: :trusted
  }

  describe "changeset/2" do
    test "accepts valid attributes with schema defaults applied" do
      changeset = Membership.changeset(@valid_attrs)

      assert changeset.valid?
      assert changeset.data.approver == false
      assert changeset.data.active_heads == []
      assert Ecto.Changeset.get_field(changeset, :role) == :trusted
    end

    test "casts role from a string and applies it" do
      changeset = Membership.changeset(Map.put(@valid_attrs, :role, "trusted"))

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :role) == :trusted
    end

    test "requires user_id, project_id, and role" do
      changeset = Membership.changeset(%{})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset, :user_id)
      assert "can't be blank" in errors_on(changeset, :project_id)
      assert "can't be blank" in errors_on(changeset, :role)
    end

    test "rejects an unknown role" do
      changeset = Membership.changeset(Map.put(@valid_attrs, :role, :admin))

      refute changeset.valid?
      assert errors_on(changeset, :role) != []
    end

    test "accepts all three defined roles" do
      for role <- [:owner, :trusted, :viewer] do
        assert Membership.changeset(Map.put(@valid_attrs, :role, role)).valid?
      end
    end

    test "casts active_heads as a UUID list" do
      heads = [Ecto.UUID.generate(), Ecto.UUID.generate()]
      changeset = Membership.changeset(Map.put(@valid_attrs, :active_heads, heads))

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :active_heads) == heads
    end

    test "allows a nil supervisor and session_pointer" do
      changeset = Membership.changeset(Map.put(@valid_attrs, :supervisor, nil))

      assert changeset.valid?
    end

    test "casts the preferences version" do
      version = DateTime.utc_now()
      changeset = Membership.changeset(Map.put(@valid_attrs, :preferences_updated_at, version))

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :preferences_updated_at) == version
    end

    test "rejects a malformed supervisor uuid" do
      changeset = Membership.changeset(Map.put(@valid_attrs, :supervisor, "nope"))

      refute changeset.valid?
      assert errors_on(changeset, :supervisor) != []
    end
  end

  defp errors_on(changeset, field) do
    changeset.errors
    |> Keyword.get_values(field)
    |> Enum.map(fn {message, _opts} -> message end)
  end
end
