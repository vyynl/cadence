defmodule Cadence.ServerWeb.DAGLayoutTest do
  use ExUnit.Case, async: true

  alias Cadence.ServerWeb.DAGLayout

  @t0 ~U[2026-10-24 12:00:00.000000Z]

  describe "layout/2" do
    test "returns an empty layout" do
      layout = DAGLayout.layout([])

      assert layout.nodes == []
      assert layout.edges == []
      assert layout.default_id == nil
      assert layout.count == 0
    end

    test "lays out a linear chain top to bottom" do
      nodes = [
        node("a", [], created_at: @t0),
        node("b", ["a"], created_at: @t0),
        node("c", ["b"], created_at: @t0)
      ]

      layout = DAGLayout.layout(nodes, default_id: "c", intro_ms: 1000)

      assert layout.count == 3
      assert layout.default_id == "c"
      assert Enum.map(layout.nodes, & &1.id) == ["a", "b", "c"]
      assert [a, b, c] = layout.nodes
      assert a.y < b.y and b.y < c.y
      assert a.x == b.x and b.x == c.x
      assert length(layout.edges) == 2
      assert Enum.all?(layout.edges, & &1.intro?)
      assert Enum.all?(layout.nodes, & &1.intro?)
      assert layout.pulse_delay == 550
      assert layout.pane_delay == 950
    end

    test "orders branches and melds" do
      nodes = [
        node("root", [], created_at: @t0),
        node("left", ["root"], created_at: DateTime.add(@t0, 1, :second)),
        node("right", ["root"], created_at: DateTime.add(@t0, 2, :second)),
        node("meld", ["left", "right"], created_at: DateTime.add(@t0, 3, :second))
      ]

      layout = DAGLayout.layout(nodes, default_id: "meld", intro_ms: 1000)

      left = Enum.find(layout.nodes, &(&1.id == "left"))
      right = Enum.find(layout.nodes, &(&1.id == "right"))
      meld = Enum.find(layout.nodes, &(&1.id == "meld"))

      assert left.y == right.y
      assert left.x < right.x
      assert meld.y > left.y
      assert length(layout.edges) == 4
      assert Enum.all?(layout.nodes, & &1.intro?)
    end

    test "wraps a wide layer into bands with break lines" do
      nodes =
        for i <- 1..12 do
          node("n#{i}", [], created_at: DateTime.add(@t0, i, :second))
        end

      layout = DAGLayout.layout(nodes, default_id: "n1", intro_ms: 1000, max_columns: 4)

      assert layout.count == 12
      assert length(layout.break_lines) == 2
      assert layout.width == 24 * 2 + 3 * 44

      ys = layout.nodes |> Enum.map(& &1.y) |> Enum.uniq() |> Enum.sort()
      assert length(ys) == 3
    end

    test "marks only the default node's ancestor lineage as intro" do
      nodes = [
        node("root", [], created_at: @t0),
        node("a", ["root"], created_at: DateTime.add(@t0, 1, :second)),
        node("default", ["a"], created_at: DateTime.add(@t0, 2, :second)),
        node("other_root", [], created_at: DateTime.add(@t0, 3, :second)),
        node("other", ["other_root"], created_at: DateTime.add(@t0, 4, :second))
      ]

      layout = DAGLayout.layout(nodes, default_id: "default", intro_ms: 1000)

      assert ids(layout.nodes, & &1.intro?) == ["a", "default", "root"]
      assert ids(layout.nodes, &(not &1.intro?)) == ["other", "other_root"]

      intro_edges = layout.edges |> Enum.filter(& &1.intro?) |> Enum.map(& &1.to)
      assert Enum.sort(intro_edges) == ["a", "default"]
    end

    test "uses the preview node when no default is supplied" do
      nodes = [
        node("root", [], flags: [:"in-progress"], created_at: @t0),
        node("functioning", ["root"],
          flags: [:functioning],
          created_at: DateTime.add(@t0, 1, :second)
        ),
        node("newer", ["root"],
          flags: [:"in-progress"],
          created_at: DateTime.add(@t0, 2, :second)
        )
      ]

      layout = DAGLayout.layout(nodes, intro_ms: 1000)

      assert layout.default_id == "functioning"
    end
  end

  defp node(id, parents, opts) do
    %{
      id: id,
      parents: parents,
      flags: Keyword.get(opts, :flags, [:"in-progress"]),
      pinned: Keyword.get(opts, :pinned, false),
      message: Keyword.get(opts, :message, "node #{id}"),
      created_at: Keyword.get(opts, :created_at, @t0)
    }
  end

  defp ids(nodes, fun), do: nodes |> Enum.filter(fun) |> Enum.map(& &1.id) |> Enum.sort()
end
