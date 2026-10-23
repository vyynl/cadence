defmodule Cadence.Shared.NodeTest do
  use ExUnit.Case, async: true

  alias Cadence.Shared.Node

  @valid_attrs %{
    project_id: Ecto.UUID.generate(),
    git_commit_sha: String.duplicate("a", 40),
    created_by: Ecto.UUID.generate(),
    created_at: DateTime.utc_now(),
    docs_state: :pending
  }

  describe "changeset/2" do
    test "accepts valid attributes with schema defaults applied" do
      changeset = Node.changeset(@valid_attrs)

      assert changeset.valid?
      assert changeset.data.pinned == false
      assert changeset.data.flags == []
      assert changeset.data.parents == []
      assert changeset.data.session_metadata == %{}
    end

    test "casts flags and docs_state from strings to atoms" do
      attrs = Map.merge(@valid_attrs, %{flags: ["functioning", "broken"], docs_state: "pending"})
      changeset = Node.changeset(attrs)

      assert changeset.valid?
      assert Ecto.Changeset.fetch_change(changeset, :flags) == {:ok, [:functioning, :broken]}
      assert Ecto.Changeset.get_field(changeset, :docs_state) == :pending
    end

    test "requires project_id, git_commit_sha, created_by, created_at, and docs_state" do
      changeset = Node.changeset(%{})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset, :project_id)
      assert "can't be blank" in errors_on(changeset, :git_commit_sha)
      assert "can't be blank" in errors_on(changeset, :created_by)
      assert "can't be blank" in errors_on(changeset, :created_at)
      assert "can't be blank" in errors_on(changeset, :docs_state)
    end

    test "rejects unknown flags" do
      changeset = Node.changeset(Map.put(@valid_attrs, :flags, [:functioning, :nope]))

      refute changeset.valid?
      assert errors_on(changeset, :flags) != []
    end

    test "rejects invalid docs_state" do
      changeset = Node.changeset(Map.put(@valid_attrs, :docs_state, :nope))

      refute changeset.valid?
      assert errors_on(changeset, :docs_state) != []
    end

    test "rejects a malformed commit SHA" do
      changeset = Node.changeset(Map.put(@valid_attrs, :git_commit_sha, "not-a-sha"))

      refute changeset.valid?
      assert errors_on(changeset, :git_commit_sha) != []
    end

    test "rejects malformed UUID fields" do
      changeset = Node.changeset(Map.put(@valid_attrs, :project_id, "nope"))

      refute changeset.valid?
      assert errors_on(changeset, :project_id) != []
    end
  end

  defp errors_on(changeset, field) do
    changeset.errors
    |> Keyword.get_values(field)
    |> Enum.map(fn {message, _opts} -> message end)
  end
end
