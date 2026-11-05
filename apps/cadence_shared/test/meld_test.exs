defmodule Cadence.Shared.MeldTest do
  use ExUnit.Case, async: true

  alias Cadence.Shared.Meld

  describe "union/1" do
    test "identical parents agree on every path" do
      files = %{"a.txt" => file("a"), "src/b.ex" => file("b")}

      union = Meld.union([parent("p1", files), parent("p2", files)])

      assert union.conflicts == %{}
      assert Map.keys(union.agreed) |> Enum.sort() == ["a.txt", "src/b.ex"]
      assert union.agreed["a.txt"].content == "a"
    end

    test "disjoint parents are fully agreed" do
      union =
        Meld.union([
          parent("p1", %{"a.txt" => file("a")}),
          parent("p2", %{"b.txt" => file("b")})
        ])

      assert union.conflicts == %{}
      assert union.agreed["a.txt"].content == "a"
      assert union.agreed["b.txt"].content == "b"
    end

    test "differing refs are a conflict, versions keep parent order" do
      union =
        Meld.union([
          parent("p1", %{"a.txt" => file("one")}),
          parent("p2", %{"a.txt" => file("two")})
        ])

      assert union.agreed == %{}

      assert %{"a.txt" => [first, second]} = union.conflicts
      assert first.id == "p1"
      assert first.content == "one"
      assert second.id == "p2"
      assert second.content == "two"
    end

    test "presence versus absence is not a conflict" do
      union =
        Meld.union([
          parent("p1", %{"a.txt" => file("a")}),
          parent("p2", %{})
        ])

      assert union.conflicts == %{}
      assert union.agreed["a.txt"].content == "a"
    end

    test "a path missing from every parent is absent" do
      union = Meld.union([parent("p1", %{}), parent("p2", %{})])

      assert union == %{agreed: %{}, conflicts: %{}}
    end

    test "conflict paths are sorted and duplicate versions are kept" do
      union =
        Meld.union([
          parent("p1", %{"z.txt" => file("z1"), "a.txt" => file("a1")}),
          parent("p2", %{"z.txt" => file("z2"), "a.txt" => file("a2")})
        ])

      assert Map.keys(union.conflicts) == ["a.txt", "z.txt"]
      assert Enum.map(union.conflicts["a.txt"], & &1.id) == ["p1", "p2"]
    end
  end

  describe "apply_ops/3" do
    setup do
      union = %{
        agreed: %{"keep.txt" => file("keep")},
        conflicts: %{
          "mod.txt" => [version("p1", "old"), version("p2", "other")],
          "gone.txt" => [version("p1", "x"), version("p2", "y")]
        }
      }

      %{union: union}
    end

    test "modify and delete resolve conflicts and keep agreed paths", %{union: union} do
      assert Meld.apply_ops(union, [
               {:modify, "mod.txt", "resolved"},
               {:delete, "gone.txt"}
             ]) == {:ok, %{"keep.txt" => "keep", "mod.txt" => "resolved"}}
    end

    test "create resolves a conflict path with new content", %{union: union} do
      assert {:ok, result} =
               Meld.apply_ops(union, [
                 {:create, "mod.txt", "created"},
                 {:modify, "gone.txt", "still here"}
               ])

      assert result["mod.txt"] == "created"
      assert result["gone.txt"] == "still here"
    end

    test "an empty content file is allowed", %{union: union} do
      assert {:ok, result} =
               Meld.apply_ops(union, [
                 {:modify, "mod.txt", ""},
                 {:delete, "gone.txt"}
               ])

      assert result["mod.txt"] == ""
    end

    test "ops on agreed or unknown paths are rejected", %{union: union} do
      assert Meld.apply_ops(union, [
               {:modify, "keep.txt", "nope"},
               {:delete, "gone.txt"}
             ]) == {:error, :unknown_path}

      assert Meld.apply_ops(union, [
               {:modify, "never.txt", "nope"},
               {:delete, "gone.txt"}
             ]) == {:error, :unknown_path}
    end

    test "the same path twice is a duplicate op", %{union: union} do
      assert Meld.apply_ops(union, [
               {:modify, "mod.txt", "a"},
               {:delete, "mod.txt"}
             ]) == {:error, :duplicate_op}
    end

    test "unsafe paths are rejected before allowlist checks", %{union: union} do
      assert Meld.apply_ops(union, [
               {:modify, "../escape.txt", "x"},
               {:delete, "gone.txt"}
             ]) == {:error, :unsafe_path}
    end

    test "every conflict must be resolved exactly once", %{union: union} do
      assert Meld.apply_ops(union, [{:modify, "mod.txt", "x"}]) ==
               {:error, :unresolved_conflict}
    end

    test "malformed operations are rejected without raising", %{union: union} do
      assert Meld.apply_ops(union, [{:rename, "mod.txt", "x"}, {:delete, "gone.txt"}]) ==
               {:error, :invalid_operation}
    end

    test "caps are enforced", %{union: union} do
      assert Meld.apply_ops(
               union,
               [{:modify, "mod.txt", "x"}, {:delete, "gone.txt"}],
               max_ops: 1
             ) == {:error, :too_many_ops}

      assert Meld.apply_ops(
               union,
               [{:modify, "mod.txt", "1234"}, {:delete, "gone.txt"}],
               max_file_bytes: 3
             ) == {:error, :file_too_large}
    end
  end

  test "intended_flag/0 is always in-progress" do
    assert Meld.intended_flag() == :"in-progress"
  end

  defp parent(id, files) do
    %{id: id, message: "message #{id}", flags: [:"in-progress"], files: files}
  end

  defp file(content) do
    %{ref: :crypto.hash(:sha, content) |> Base.encode16(case: :lower), content: content}
  end

  defp version(id, content) do
    %{id: id, ref: :crypto.hash(:sha, content) |> Base.encode16(case: :lower), content: content}
  end
end
