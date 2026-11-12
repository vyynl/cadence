defmodule Cadence.ServerWeb.DAGLayout do
  @moduledoc """
  Pure layout for the web DAG.

  Consumes project nodes and produces SVG coordinates, elbow edge paths, wrapped
  layer bands, and the intro-animation metadata. No Phoenix or database code
  here, so the layout is unit-testable.
  """

  alias Cadence.Shared.DAG

  @radius 8
  @x_spacing 44
  @band_height 56
  @layer_gap 40
  @margin_x 24
  @margin_y 24
  @default_max_columns 10
  @flag_priority [:broken, :"in-progress", :sandbox, :functioning]

  @doc """
  Lay out `nodes` for SVG rendering.

  Options:
    * `:default_id` — node to pulse after the intro (defaults to preview node)
    * `:intro_ms` — intro duration; 0 disables timing
    * `:max_columns` — nodes per band before wrapping (default 10)
  """
  @spec layout([map() | struct()], keyword()) :: map()
  def layout(nodes, opts \\ []) do
    nodes = Enum.map(nodes, &normalize/1)

    if nodes == [] do
      %{
        nodes: [],
        edges: [],
        break_lines: [],
        width: @margin_x * 2,
        height: @margin_y * 2,
        default_id: nil,
        intro_ms: 0,
        pulse_delay: 0,
        rest_delay: 0,
        pane_delay: 0,
        count: 0
      }
    else
      build(nodes, opts)
    end
  end

  defp build(nodes, opts) do
    depths = DAG.depths(nodes)
    grouped = Enum.group_by(nodes, &Map.get(depths, &1.id, 0))
    max_depth = grouped |> Map.keys() |> Enum.max()
    max_columns = max(opts[:max_columns] || @default_max_columns, 1)
    intro_ms = max(opts[:intro_ms] || 0, 0)

    {placed, break_lines, height} = place_layers(grouped, max_depth, max_columns)

    # The rail is left-aligned (§7.3): the SVG is only as wide as the columns
    # actually occupied, capped by max_columns. Using max_columns here would
    # reserve 10 columns (444px) for every graph and overflow a narrow rail.
    used_columns =
      grouped
      |> Map.values()
      |> Enum.map(&min(length(&1), max_columns))
      |> Enum.max(fn -> 1 end)

    by_id = Map.new(nodes, &{&1.id, &1})
    default_id = resolve_default(opts[:default_id], nodes, placed)
    lineage = lineage_ids(default_id, by_id)

    # No default means no lineage to animate: keep the timing at zero instead
    # of delaying the pane for an intro that draws nothing.
    effective_intro_ms = if default_id == nil, do: 0, else: intro_ms

    {pulse_delay, rest_delay, pane_delay, edge_duration, step} =
      intro_timing(effective_intro_ms, lineage, depths)

    placed_nodes =
      nodes
      |> Enum.map(fn node ->
        position = Map.fetch!(placed, node.id)
        depth = Map.get(depths, node.id, 0)
        intro? = MapSet.member?(lineage, node.id)
        delay = node_delay(intro?, depth, step, edge_duration, rest_delay)

        Map.merge(node, %{
          depth: depth,
          x: position.x,
          y: position.y,
          intro?: intro?,
          delay: delay
        })
      end)
      |> Enum.sort_by(&{&1.y, &1.x, &1.id})

    edges =
      DAG.edges(nodes)
      # A trimmed node list (the render cap, §7.3) still carries edges from
      # parents outside the window: keep a boundary child attached to its
      # rendered parent, and drop the phantom edge to the missing parent.
      |> Enum.filter(&Map.has_key?(placed, &1.from))
      |> Enum.map(fn edge ->
        from = Map.fetch!(placed, edge.from)
        to = Map.fetch!(placed, edge.to)
        child = Map.fetch!(by_id, edge.to)
        depth = Map.get(depths, edge.to, 0)
        intro? = MapSet.member?(lineage, edge.from) and MapSet.member?(lineage, edge.to)
        delay = if intro?, do: round(max(depth - 1, 0) * step), else: rest_delay

        %{
          from: edge.from,
          to: edge.to,
          path: edge_path(from, to),
          flag: child.flag,
          intro?: intro?,
          delay: delay,
          duration: if(intro?, do: edge_duration, else: 240)
        }
      end)
      |> Enum.sort_by(&{depths[&1.from] || 0, depths[&1.to] || 0, &1.from, &1.to})

    %{
      nodes: placed_nodes,
      edges: edges,
      break_lines: break_lines,
      width: @margin_x * 2 + (used_columns - 1) * @x_spacing,
      height: height,
      default_id: default_id,
      intro_ms: effective_intro_ms,
      pulse_delay: pulse_delay,
      rest_delay: rest_delay,
      pane_delay: pane_delay,
      count: length(nodes)
    }
  end

  defp normalize(node) do
    flags = Map.get(node, :flags) || []

    %{
      id: Map.fetch!(node, :id),
      parents: Map.get(node, :parents) || [],
      flags: flags,
      pinned: Map.get(node, :pinned) == true,
      message: Map.get(node, :message) || "",
      created_at: Map.get(node, :created_at),
      flag: primary_flag(flags)
    }
  end

  defp primary_flag(flags) do
    Enum.find(@flag_priority, &(&1 in flags))
  end

  defp resolve_default(requested, nodes, placed) do
    candidate =
      requested ||
        case DAG.preview_node(nodes) do
          nil -> nil
          node -> node.id
        end

    if candidate && Map.has_key?(placed, candidate), do: candidate, else: nil
  end

  defp lineage_ids(nil, _by_id), do: MapSet.new()

  defp lineage_ids(id, by_id) do
    collect_lineage(id, by_id, MapSet.new())
  end

  defp collect_lineage(id, by_id, seen) do
    if MapSet.member?(seen, id) do
      seen
    else
      seen = MapSet.put(seen, id)

      case Map.get(by_id, id) do
        nil -> seen
        node -> Enum.reduce(node.parents, seen, &collect_lineage(&1, by_id, &2))
      end
    end
  end

  defp intro_timing(0, _lineage, _depths) do
    {0, 0, 0, 0, 0.0}
  end

  defp intro_timing(intro_ms, lineage, depths) do
    lineage_depth =
      lineage
      |> Enum.map(&Map.get(depths, &1, 0))
      |> Enum.max(fn -> 0 end)

    draw_window = intro_ms * 0.55
    step = if lineage_depth > 0, do: draw_window / lineage_depth, else: 0.0
    edge_duration = max(120, round(step * 0.9))

    {
      round(intro_ms * 0.55),
      round(intro_ms * 0.95),
      round(intro_ms * 0.95),
      edge_duration,
      step
    }
  end

  defp node_delay(true, 0, _step, _edge_duration, _rest_delay), do: 0

  defp node_delay(true, depth, step, edge_duration, _rest_delay) do
    round(max(depth - 1, 0) * step) + round(edge_duration * 0.5)
  end

  defp node_delay(false, _depth, _step, _edge_duration, rest_delay), do: rest_delay

  defp place_layers(grouped, max_depth, max_columns) do
    {placed, break_lines, current_y} =
      Enum.reduce(0..max_depth, {%{}, [], @margin_y}, fn depth, {placed, breaks, y} ->
        layer =
          grouped
          |> Map.get(depth, [])
          |> sort_layer(depth, placed)

        bands = Enum.chunk_every(layer, max_columns)

        {placed, breaks} =
          bands
          |> Enum.with_index()
          |> Enum.reduce({placed, breaks}, fn {band, band_index}, {placed, breaks} ->
            band_y = y + band_index * @band_height

            placed =
              band
              |> Enum.with_index()
              |> Enum.reduce(placed, fn {node, col_index}, acc ->
                Map.put(acc, node.id, %{
                  x: @margin_x + col_index * @x_spacing,
                  y: band_y,
                  depth: depth
                })
              end)

            breaks =
              if band_index > 0 do
                [band_y - div(@band_height, 2) | breaks]
              else
                breaks
              end

            {placed, breaks}
          end)

        next_y = y + max(length(bands) - 1, 0) * @band_height + @layer_gap
        {placed, breaks, next_y}
      end)

    height = max(current_y - @layer_gap + @margin_y, @margin_y * 2)
    {placed, Enum.reverse(break_lines), height}
  end

  defp sort_layer(layer, 0, _placed) do
    Enum.sort_by(layer, &{created_key(&1), &1.id})
  end

  defp sort_layer(layer, _depth, placed) do
    Enum.sort_by(layer, fn node ->
      xs =
        Enum.flat_map(node.parents, fn parent_id ->
          case Map.get(placed, parent_id) do
            %{x: x} -> [x]
            _ -> []
          end
        end)

      desired = if xs == [], do: 0, else: Enum.sum(xs) / length(xs)
      {desired, created_key(node), node.id}
    end)
  end

  defp created_key(%{created_at: %DateTime{} = datetime}) do
    DateTime.to_unix(datetime, :microsecond)
  end

  defp created_key(_node), do: 0

  defp edge_path(%{x: px, y: py}, %{x: cx, y: cy}) do
    start_y = py + @radius
    end_y = cy - @radius

    cond do
      cx == px ->
        "M #{px} #{start_y} L #{cx} #{end_y}"

      end_y <= start_y ->
        "M #{px} #{start_y} L #{cx} #{end_y}"

      true ->
        elbow_y = start_y + abs(cx - px)

        if elbow_y >= end_y do
          "M #{px} #{start_y} L #{cx} #{end_y}"
        else
          "M #{px} #{start_y} L #{cx} #{elbow_y} L #{cx} #{end_y}"
        end
    end
  end
end
