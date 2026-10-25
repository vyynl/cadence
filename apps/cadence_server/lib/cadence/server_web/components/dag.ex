defmodule Cadence.ServerWeb.Components.DAG do
  @moduledoc """
  Server-rendered SVG DAG for the project home.
  """

  use Cadence.ServerWeb, :html

  attr(:layout, :map, required: true)
  attr(:selected_id, :string, default: nil)
  attr(:project_slug, :string, required: true)

  def dag(assigns) do
    ~H"""
    <div class="dag-panel">
      <div class="dag-scroll">
        <div class="dag-canvas" style={"width: #{@layout.width}px"}>
          <svg
            viewBox={"0 0 #{@layout.width} #{@layout.height}"}
            width={@layout.width}
            height={@layout.height}
            role="img"
            aria-labelledby="cadence-dag-title"
          >
            <title id="cadence-dag-title">Project session graph</title>

            <line
              :for={y <- @layout.break_lines}
              class="dag-break"
              x1="0"
              y1={y}
              x2={@layout.width}
              y2={y}
            />

            <g class="dag-edges">
              <path
                :for={edge <- @layout.edges}
                d={edge.path}
                pathLength="1"
                class={edge_classes(edge)}
                style={edge_style(edge)}
              />
            </g>

            <g class="dag-nodes">
              <.link
                :for={node <- @layout.nodes}
                patch={~p"/p/#{@project_slug}/n/#{node.id}"}
                class={node_classes(node, @selected_id, @layout.default_id)}
                style={node_style(node, @layout)}
                aria-label={node_label(node)}
                aria-current={if node.id == @selected_id, do: "true"}
              >
                <circle
                  class={"node-dot flag-#{node.flag || "unknown"}"}
                  cx={node.x}
                  cy={node.y}
                  r="8"
                />
                <circle :if={node.pinned} class="node-ring" cx={node.x} cy={node.y} r="12" />
                <circle
                  :if={node.id == @selected_id}
                  class="node-selected"
                  cx={node.x}
                  cy={node.y}
                  r="14"
                />
                <foreignObject
                  class="dag-tooltip"
                  x={tooltip_x(node, @layout.width)}
                  y={tooltip_y(node)}
                  width="240"
                  height="58"
                >
                  <div xmlns="http://www.w3.org/1999/xhtml" class="dag-tooltip-body">
                    <strong>{node.message || "(no message)"}</strong>
                    <span>{status_text(node)}</span>
                  </div>
                </foreignObject>
              </.link>
            </g>
          </svg>
        </div>
      </div>
    </div>
    """
  end

  defp edge_classes(edge) do
    [
      "dag-edge",
      if(edge.intro?, do: "intro", else: "rest"),
      "flag-#{edge.flag || "unknown"}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp edge_style(edge) do
    "--edge-delay: #{edge.delay}ms; --edge-duration: #{edge.duration}ms;"
  end

  defp node_classes(node, selected_id, default_id) do
    [
      "dag-node",
      if(node.intro?, do: "intro", else: "rest"),
      if(node.id == default_id, do: "default"),
      if(node.id == selected_id, do: "selected")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp node_style(node, layout) do
    "--node-delay: #{node.delay}ms; --pulse-delay: #{layout.pulse_delay}ms; --rest-delay: #{layout.rest_delay}ms;"
  end

  defp node_label(node) do
    "Node: #{node.message || "(no message)"}. Status: #{status_text(node)}."
  end

  defp status_text(node) do
    flags =
      case node.flags do
        [] -> "no flags"
        flags -> Enum.map_join(flags, ", ", &Atom.to_string/1)
      end

    if node.pinned, do: flags <> " · pinned", else: flags
  end

  defp tooltip_x(node, width) do
    max(node.x + 12, 0) |> min(max(width - 248, 0))
  end

  defp tooltip_y(node) when node.y < 70, do: node.y + 16
  defp tooltip_y(node), do: node.y - 68
end
