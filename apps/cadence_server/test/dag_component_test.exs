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
end
