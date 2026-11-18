defmodule Cadence.Daemon.TUI.DAGTest do
  use ExUnit.Case, async: true

  alias Cadence.Daemon.TUI.DAG

  defp graph do
    %{
      "nodes" => [
        node("a", [], depth: 0, created_at: "2026-01-01T00:00:00Z"),
        node("b", ["a"], depth: 1, created_at: "2026-01-02T00:00:00Z", flags: ["functioning"]),
        node("c", ["a"],
          depth: 1,
          created_at: "2026-01-03T00:00:00Z",
          flags: ["sandbox"],
          pinned: true
        )
      ],
      "edges" => [%{"from" => "a", "to" => "b"}, %{"from" => "a", "to" => "c"}],
      "default_node_id" => "b",
      "preview_node_id" => "c",
      "session" => %{"session_pointer" => "b"}
    }
  end

  defp node(id, parents, opts) do
    %{
      "id" => id,
      "parents" => parents,
      "depth" => Keyword.fetch!(opts, :depth),
      "flags" => Keyword.get(opts, :flags, []),
      "pinned" => Keyword.get(opts, :pinned, false),
      "created_at" => Keyword.fetch!(opts, :created_at),
      "message" => "message #{id}"
    }
  end

  test "places one glyph row per layer with an edge row between layers" do
    layout = DAG.layout(graph())

    assert layout.height == 3
    assert layout.max_depth == 1
    assert layout.width == 4

    assert layout.nodes["a"].row == 0
    assert layout.nodes["b"].row == 2
    assert layout.nodes["c"].row == 2

    assert layout.nodes["a"].col == 0
    assert layout.nodes["b"].col == 0
    assert layout.nodes["c"].col == 3
  end

  test "draws the connector glyphs between a parent and its children" do
    layout = DAG.layout(graph())

    assert DAG.row_text(Enum.at(layout.rows, 0), layout.width) == "●"
    assert DAG.row_text(Enum.at(layout.rows, 1), layout.width) == "|--|"
    assert DAG.row_text(Enum.at(layout.rows, 2), layout.width) == "●  ◉"
  end

  test "marks the current, preview, and pinned nodes" do
    layout = DAG.layout(graph())

    assert layout.nodes["b"].marks == [:current]
    assert Enum.sort(layout.nodes["c"].marks) == [:pinned, :preview]
    assert layout.nodes["a"].marks == []

    assert Enum.at(layout.rows, 2).marks == [:current, :preview, :pinned]
  end

  test "records the primary flag for colouring" do
    layout = DAG.layout(graph())

    assert layout.nodes["a"].primary_flag == nil
    assert layout.nodes["b"].primary_flag == "functioning"
    assert layout.nodes["c"].primary_flag == "sandbox"
  end

  test "move/3 clamps at the edges and picks the nearest cell" do
    layout = DAG.layout(graph())

    assert DAG.move(layout, "a", :down) == "b"
    assert DAG.move(layout, "b", :right) == "c"
    assert DAG.move(layout, "b", :left) == nil
    assert DAG.move(layout, "c", :left) == "b"
    assert DAG.move(layout, "b", :up) == "a"
    assert DAG.move(layout, "a", :up) == nil
    assert DAG.move(layout, "missing", :down) == nil
    assert DAG.move(layout, nil, :down) == nil
  end

  test "default_id/2 prefers a placed node and falls back to the top-left" do
    layout = DAG.layout(graph())

    assert DAG.default_id(layout, "c") == "c"
    assert DAG.default_id(layout, "missing") == "a"
    assert DAG.default_id(layout, nil) == "a"
  end

  test "trim/3 keeps the focused node visible in a narrow rail" do
    layout = DAG.layout(graph())

    trimmed = DAG.trim(layout, 2, "c")
    assert trimmed.width == 2
    assert trimmed.col_offset == 2
    assert DAG.row_text(Enum.at(trimmed.rows, 2), 2) == " ◉"

    # A wide enough rail is unchanged.
    assert DAG.trim(layout, 10, "c") == layout
    assert DAG.trim(layout, 0, "c") == layout
  end

  test "node_at/3 resolves a grid cell to a node" do
    layout = DAG.layout(graph())

    assert DAG.node_at(layout, 2, 0) == "b"
    assert DAG.node_at(layout, 2, 3) == "c"
    assert DAG.node_at(layout, 2, 1) == nil
    assert DAG.node_at(layout, 99, 0) == nil
  end

  test "handles an empty graph without crashing" do
    layout = DAG.layout(%{"nodes" => [], "edges" => []})

    assert layout.nodes == %{}
    assert layout.height == 1
    assert layout.width == 1
    assert DAG.default_id(layout, nil) == nil
  end

  test "step/1 controls horizontal spacing" do
    layout =
      DAG.layout(%{
        "nodes" => [
          %{"id" => "a", "parents" => [], "depth" => 0, "flags" => [], "created_at" => "1"},
          %{"id" => "b", "parents" => [], "depth" => 0, "flags" => [], "created_at" => "2"}
        ],
        "edges" => []
      })

    assert layout.nodes["a"].col == 0
    assert layout.nodes["b"].col == 3

    wide =
      DAG.layout(
        %{
          "nodes" => [
            %{"id" => "a", "parents" => [], "depth" => 0, "flags" => [], "created_at" => "1"},
            %{"id" => "b", "parents" => [], "depth" => 0, "flags" => [], "created_at" => "2"}
          ],
          "edges" => []
        },
        step: 5
      )

    assert wide.nodes["b"].col == 5
  end

  test "tolerates malformed nodes, depths, and edges" do
    layout =
      DAG.layout(%{
        "nodes" => [
          nil,
          %{"id" => "x", "depth" => "0", "flags" => "broken"},
          %{"id" => "y", "depth" => -3}
        ],
        "edges" => ["bad", %{"from" => "x", "to" => "missing"}]
      })

    assert layout.nodes["x"].row == 0
    assert layout.nodes["y"].row == 0
    assert layout.width >= 1
    assert is_list(layout.rows)
  end

  test "flag priority picks the most severe flag" do
    layout =
      DAG.layout(%{
        "nodes" => [
          %{
            "id" => "a",
            "parents" => [],
            "depth" => 0,
            "flags" => ["functioning", "broken", "sandbox"],
            "created_at" => "1"
          }
        ],
        "edges" => []
      })

    assert layout.nodes["a"].primary_flag == "broken"
  end
end
