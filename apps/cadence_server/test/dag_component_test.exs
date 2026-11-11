defmodule Cadence.ServerWeb.Components.DAGTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Cadence.ServerWeb.Components.DAG
  alias Cadence.ServerWeb.DAGLayout

  @t0 ~U[2026-10-24 12:00:00.000000Z]

  test "a pinned flagless node reads as pinned in the tooltip and label" do
    node = %{
      id: "n1",
      parents: [],
      flags: [],
      pinned: true,
      message: "root",
      created_at: @t0
    }

    layout = DAGLayout.layout([node], intro_ms: 0)

    html =
      render_component(&DAG.dag/1, %{
        layout: layout,
        selected_id: "n1",
        project_slug: "demo"
      })

    assert html =~ "Status: pinned."
    assert html =~ ">pinned<"
    refute html =~ "no flags"
  end

  test "the hover card is painted after every node graphic" do
    nodes = [
      %{
        id: "root",
        parents: [],
        flags: [:functioning],
        pinned: false,
        message: "root",
        created_at: @t0
      },
      %{
        id: "child",
        parents: ["root"],
        flags: [:"in-progress"],
        pinned: false,
        message: "child",
        created_at: @t0
      }
    ]

    layout = DAGLayout.layout(nodes, intro_ms: 0)

    html =
      render_component(&DAG.dag/1, %{
        layout: layout,
        selected_id: "root",
        project_slug: "demo"
      })

    # The SVG name is an aria-label, not a <title> (which browsers also show as
    # a native hover tooltip).
    refute html =~ "<title"
    assert html =~ ~s(aria-label="Project session graph")

    # The interaction layer (hit circles + cards) comes after the visual nodes,
    # so no node graphic can paint over a hovered card.
    {node_layer, _} = :binary.match(html, ~s(class="dag-nodes"))
    {overlay, _} = :binary.match(html, ~s(class="dag-overlay"))
    {tooltip, _} = :binary.match(html, ~s(class="dag-tooltip"))
    assert overlay > node_layer
    assert tooltip > node_layer

    # One interactive link per node; the card is inside the link.
    assert length(Regex.scan(~r/<a\s/, html)) == length(layout.nodes)
    assert html =~ ~s(class="node-hit")
  end

  test "the canvas width matches the columns actually used" do
    nodes = [
      %{id: "root", parents: [], flags: [], pinned: false, message: "root", created_at: @t0},
      %{
        id: "child",
        parents: ["root"],
        flags: [],
        pinned: false,
        message: "child",
        created_at: @t0
      }
    ]

    layout = DAGLayout.layout(nodes, intro_ms: 0)

    html =
      render_component(&DAG.dag/1, %{
        layout: layout,
        selected_id: "root",
        project_slug: "demo"
      })

    assert layout.width == 48
    assert html =~ ~s(style="width: 48px")
    assert html =~ ~s(width="48")
  end
end
