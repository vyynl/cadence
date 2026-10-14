defmodule Cadence.Shared.DAGTest do
  use ExUnit.Case, async: true

  alias Cadence.Shared.DAG

  defp dag_node(id, parents \\ [], opts \\ []) do
    %{
      id: id,
      parents: parents,
      flags: Keyword.get(opts, :flags, []),
      pinned: Keyword.get(opts, :pinned, false),
      created_at: Keyword.get(opts, :created_at, ~U[2026-01-01 00:00:00Z]),
      created_by: Keyword.get(opts, :created_by, "u")
    }
  end

  describe "depths/1" do
    test "is empty for no nodes" do
      assert DAG.depths([]) == %{}
    end

    test "is the longest path from a root (linear)" do
      nodes = [dag_node("a"), dag_node("b", ["a"]), dag_node("c", ["b"])]
      assert DAG.depths(nodes) == %{"a" => 0, "b" => 1, "c" => 2}
    end

    test "puts siblings on the same layer" do
      nodes = [dag_node("a"), dag_node("b", ["a"]), dag_node("c", ["a"])]
      assert DAG.depths(nodes) == %{"a" => 0, "b" => 1, "c" => 1}
    end

    test "a meld sits one below its deepest parent" do
      nodes = [
        dag_node("r"),
        dag_node("x", ["r"]),
        dag_node("y", ["r"]),
        dag_node("m", ["x", "y"])
      ]

      assert DAG.depths(nodes) == %{"r" => 0, "x" => 1, "y" => 1, "m" => 2}
    end

    test "handles multiple roots" do
      nodes = [dag_node("a"), dag_node("b"), dag_node("c", ["a"])]
      assert DAG.depths(nodes) == %{"a" => 0, "b" => 0, "c" => 1}
    end

    test "raises on a cycle" do
      nodes = [dag_node("a", ["b"]), dag_node("b", ["a"])]
      assert_raise ArgumentError, fn -> DAG.depths(nodes) end
    end
  end

  describe "edges/1 and structure" do
    test "returns parent -> child edges" do
      nodes = [dag_node("a"), dag_node("b", ["a"]), dag_node("c", ["a", "b"])]

      assert Enum.sort_by(DAG.edges(nodes), & &1.to) == [
               %{from: "a", to: "b"},
               %{from: "a", to: "c"},
               %{from: "b", to: "c"}
             ]
    end

    test "roots and children" do
      nodes = [dag_node("a"), dag_node("b"), dag_node("c", ["a"]), dag_node("d", ["a", "b"])]

      assert Enum.sort(DAG.roots(nodes)) == ["a", "b"]
      assert Enum.sort(DAG.children(nodes)["a"]) == ["c", "d"]
      assert DAG.children(nodes)["b"] == ["d"]
    end
  end

  describe "preview_node/1" do
    test "is nil for an empty project" do
      assert DAG.preview_node([]) == nil
    end

    test "prefers pinned, newest first" do
      old_pin = dag_node("pin", [], pinned: true, created_at: ~U[2026-01-01 00:00:00Z])
      new_plain = dag_node("new", [], created_at: ~U[2026-02-01 00:00:00Z])

      assert DAG.preview_node([new_plain, old_pin]).id == "pin"
    end

    test "falls back to functioning, then newest" do
      broken = dag_node("broken", [], flags: [:broken], created_at: ~U[2026-02-01 00:00:00Z])
      good = dag_node("good", [], flags: [:functioning], created_at: ~U[2026-01-01 00:00:00Z])
      assert DAG.preview_node([broken, good]).id == "good"

      newer = dag_node("newer", [], flags: [:broken], created_at: ~U[2026-03-01 00:00:00Z])
      assert DAG.preview_node([broken, good, newer]).id == "good"
    end
  end

  describe "default_node/2" do
    test "uses the session pointer when it matches a node" do
      a = dag_node("a")
      b = dag_node("b", ["a"], created_by: "u")
      assert DAG.default_node([a, b], session_pointer: "a", user_id: "u").id == "a"
    end

    test "falls back to the user's most recent node" do
      mine_old = dag_node("mine1", [], created_by: "u", created_at: ~U[2026-01-01 00:00:00Z])
      mine_new = dag_node("mine2", [], created_by: "u", created_at: ~U[2026-02-01 00:00:00Z])
      other = dag_node("other", [], created_by: "v", created_at: ~U[2026-03-01 00:00:00Z])

      nodes = [mine_old, mine_new, other]
      assert DAG.default_node(nodes, user_id: "u").id == "mine2"
    end

    test "falls back to the preview node when the user has no nodes" do
      pinned = dag_node("pin", [], pinned: true, created_by: "v")
      assert DAG.default_node([pinned], user_id: "u").id == "pin"
    end

    test "is nil for an empty project" do
      assert DAG.default_node([], user_id: "u") == nil
    end
  end
end
