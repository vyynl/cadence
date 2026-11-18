defmodule Cadence.Daemon.TUI.DAG do
  @moduledoc """
  Pure character-grid layout for the TUI's DAG rail.

  Consumes the `GET /graph` payload (string keys, exactly as the daemon's JSON
  socket router emits it) and produces one glyph row per DAG layer plus an edge
  row between layers. This is the same shape the Neovim picker draws
  (`cadence.nvim/lua/cadence/graph.lua`), reimplemented over the JSON graph
  rather than ported line by line.

  The grid is left-aligned and unbounded; `trim/3` applies a horizontal
  viewport for a narrow rail. Node marks (`:current`, `:preview`, `:pinned`,
  plus the node's flags) are data on each node and row so the renderer can
  colour and label them without recomputing the layout.

  Symbols: `●` a node, `◉` a pinned node. Edge rows use `\\`, `/`, `|`, `-`.
  """

  @step 3

  # Highlight precedence when a node carries several flags (spec §3.1 flags).
  @flag_priority ["broken", "in-progress", "sandbox", "functioning"]

  # When two edges overlap in one cell, keep the most structural glyph.
  @glyph_rank %{"|" => 3, "\\" => 2, "/" => 2, "-" => 1}

  @typedoc "A placed node: grid position plus the marks the renderer needs."
  @type placed_node :: %{
          row: non_neg_integer(),
          col: non_neg_integer(),
          depth: non_neg_integer(),
          primary_flag: String.t() | nil,
          flags: [String.t()],
          pinned: boolean(),
          marks: [atom()]
        }

  @type cell :: %{
          col: non_neg_integer(),
          glyph: String.t(),
          kind: :node | :edge,
          node_id: String.t() | nil,
          flag: String.t() | nil
        }

  @type row :: %{
          index: non_neg_integer(),
          cells: [cell()],
          marks: [atom()],
          break: boolean()
        }

  @type t :: %{
          rows: [row()],
          nodes: %{optional(String.t()) => placed_node()},
          edges: [map()],
          height: non_neg_integer(),
          width: non_neg_integer(),
          max_depth: non_neg_integer(),
          col_offset: non_neg_integer()
        }

  @doc """
  Lays out a `GET /graph` payload.

  Options:

    * `:step` - horizontal spacing between nodes (default `#{@step}`)

  Returns the grid rows, a `nodes` map of id to placement/marks, the edge list
  it drew, and the grid dimensions.
  """
  @spec layout(map(), keyword()) :: t()
  def layout(graph, opts \\ []) when is_map(graph) do
    step = Keyword.get(opts, :step, @step)

    nodes =
      graph |> Map.get("nodes", []) |> List.wrap() |> Enum.filter(&is_map/1)

    edges =
      graph |> Map.get("edges", []) |> List.wrap() |> Enum.filter(&is_map/1)

    default_id = Map.get(graph, "default_node_id")
    preview_id = Map.get(graph, "preview_node_id")
    pointer = get_in(graph, ["session", "session_pointer"])

    by_id = Map.new(nodes, &{&1["id"], &1})
    layers = Enum.group_by(nodes, &depth_of/1)
    max_depth = layers |> Map.keys() |> Enum.max(fn -> 0 end)

    {placed, height} = place_layers(layers, max_depth, step)
    {grid, edge_cells} = draw_edges(edges, placed)
    grid = overlay_nodes(grid, placed)
    width = grid_width(placed, edge_cells)

    nodes_out =
      Map.new(placed, fn {id, cell} ->
        node = Map.get(by_id, id, %{})

        {id,
         %{
           row: cell.row,
           col: cell.col,
           depth: cell.depth,
           primary_flag: cell.flag,
           flags: cell.flags,
           pinned: cell.pinned,
           marks: marks(id, node, default_id, preview_id, pointer)
         }}
      end)

    rows =
      for r <- 0..(height - 1)//1 do
        row_cells = for {id, cell} <- placed, cell.row == r, do: {id, cell}

        %{
          index: r,
          cells: row_glyphs(r, row_cells, grid, edge_cells),
          marks: row_marks(row_cells, nodes_out),
          break: false
        }
      end

    %{
      rows: rows,
      nodes: nodes_out,
      edges: edges,
      height: height,
      width: width,
      max_depth: max_depth,
      col_offset: 0
    }
  end

  @doc """
  Moves from `from_id` towards `dir` (`:up`, `:down`, `:left`, `:right`).

  Up/down cross rows and then prefer the nearest column; left/right stay on
  the same row. Returns `nil` when there is nothing in that direction, so
  movement clamps instead of wrapping.
  """
  @spec move(t(), String.t() | nil, :up | :down | :left | :right) :: String.t() | nil
  def move(_layout, nil, _dir), do: nil

  def move(%{nodes: nodes}, from_id, dir) do
    case Map.get(nodes, from_id) do
      nil ->
        nil

      from ->
        nodes
        |> Enum.flat_map(fn {id, cell} ->
          if id == from_id do
            []
          else
            case score(from, cell, dir) do
              nil -> []
              value -> [{value, id}]
            end
          end
        end)
        |> Enum.min_by(&elem(&1, 0), fn -> nil end)
        |> case do
          nil -> nil
          {_score, id} -> id
        end
    end
  end

  @doc """
  Applies a horizontal viewport of at most `max_width` columns.

  Without a focus the window starts at column 0. With `focus_id` the window is
  shifted so the focused node's column stays visible, which is what a narrow
  rail needs. Returns the layout with `rows` clipped and `col_offset` set.
  """
  @spec trim(t(), non_neg_integer(), String.t() | nil) :: t()
  def trim(layout, max_width, focus_id \\ nil)

  def trim(%{width: width} = layout, max_width, _focus_id)
      when max_width <= 0 or width <= max_width do
    layout
  end

  def trim(layout, max_width, focus_id) do
    offset = trim_offset(layout, max_width, focus_id)

    rows =
      Enum.map(layout.rows, fn row ->
        cells =
          row.cells
          |> Enum.filter(&(&1.col >= offset and &1.col < offset + max_width))
          |> Enum.map(&%{&1 | col: &1.col - offset})

        %{row | cells: cells}
      end)

    %{layout | rows: rows, width: max_width, col_offset: offset}
  end

  @doc """
  Builds the plain-text view of one row (glyphs only, no styles).

  Used by tests and by callers that want a single string instead of cells.
  """
  @spec row_text(row(), non_neg_integer()) :: String.t()
  def row_text(%{cells: cells, break: break?}, width) do
    for col <- 0..max(width - 1, 0)//1, into: "" do
      case Enum.find(cells, &(&1.col == col)) do
        nil -> if break?, do: "╌", else: " "
        cell -> cell.glyph
      end
    end
    |> String.replace(~r/\s+$/, "")
  end

  @doc "The node occupying a grid cell, if any."
  @spec node_at(t(), non_neg_integer(), non_neg_integer()) :: String.t() | nil
  def node_at(%{rows: rows}, row, col) do
    with %{cells: cells} <- Enum.find(rows, &(&1.index == row)),
         %{node_id: id} <- Enum.find(cells, &(&1.col == col)) do
      id
    else
      _ -> nil
    end
  end

  @doc "The node to start on: `preferred` when placed, else the top-left node."
  @spec default_id(t(), String.t() | nil) :: String.t() | nil
  def default_id(%{nodes: nodes}, preferred) do
    if is_binary(preferred) and Map.has_key?(nodes, preferred) do
      preferred
    else
      nodes
      |> Enum.min_by(fn {_id, cell} -> {cell.row, cell.col} end, fn -> nil end)
      |> case do
        nil -> nil
        {id, _cell} -> id
      end
    end
  end

  # -- layout internals ------------------------------------------------------

  defp depth_of(node) do
    case node["depth"] do
      depth when is_integer(depth) and depth >= 0 -> depth
      _ -> 0
    end
  end

  defp place_layers(layers, max_depth, step) do
    Enum.reduce(0..max_depth//1, {%{}, 0}, fn depth, {placed, row} ->
      layer = Map.get(layers, depth, [])
      desired = desired_columns(layer, placed, depth, step)
      ordered = order_layer(layer, desired, depth)

      placed =
        ordered
        |> Enum.reduce({placed, -step}, fn node, {acc, prev} ->
          want = max(Map.get(desired, node["id"], 0), 0)
          # Pack the layer left to right: a node never sits left of the
          # previous one plus the step, and never left of its desired column.
          col = max(prev + step, want)

          cell = %{
            row: row,
            col: col,
            depth: depth,
            flag: primary_flag(node),
            flags: node_flags(node),
            pinned: node["pinned"] == true
          }

          {Map.put(acc, node["id"], cell), col}
        end)
        |> elem(0)

      # One glyph row per layer, plus an edge row between layers.
      next_row = row + 1 + if(depth < max_depth, do: 1, else: 0)
      {placed, next_row}
    end)
  end

  defp desired_columns(layer, _placed, 0, step) do
    layer
    |> sort_by_created()
    |> Enum.with_index()
    |> Map.new(fn {node, index} -> {node["id"], index * step} end)
  end

  defp desired_columns(layer, placed, _depth, _step) do
    Map.new(layer, fn node ->
      cols =
        node
        |> node_parents()
        |> Enum.flat_map(fn parent_id ->
          case Map.get(placed, parent_id) do
            nil -> []
            cell -> [cell.col]
          end
        end)

      desired =
        case cols do
          [] -> 0
          cols -> cols |> Enum.sum() |> Kernel./(length(cols)) |> round()
        end

      {node["id"], desired}
    end)
  end

  defp order_layer(layer, _desired, 0), do: sort_by_created(layer)

  defp order_layer(layer, desired, _depth) do
    Enum.sort_by(layer, fn node ->
      {Map.get(desired, node["id"], 0), node["created_at"] || "", node["id"] || ""}
    end)
  end

  defp sort_by_created(nodes) do
    Enum.sort_by(nodes, fn node -> {node["created_at"] || "", node["id"] || ""} end)
  end

  defp draw_edges(edges, cells) do
    Enum.reduce(edges, {%{}, %{}}, fn edge, acc ->
      parent = Map.get(cells, edge["from"])
      child = Map.get(cells, edge["to"])

      if parent && child && child.row > parent.row do
        draw_edge(parent, child, acc)
      else
        acc
      end
    end)
  end

  defp draw_edge(parent, child, acc) do
    edge_row = child.row - 1
    flag = child.flag

    # Vertical connector for any gap (a parent can be rows above).
    acc =
      Enum.reduce((parent.row + 1)..(edge_row - 1)//1, acc, fn r, a ->
        put_glyph(a, r, parent.col, "|", flag)
      end)

    if parent.col == child.col do
      put_glyph(acc, edge_row, child.col, "|", flag)
    else
      sign = if child.col > parent.col, do: 1, else: -1
      acc = put_glyph(acc, edge_row, parent.col, if(sign > 0, do: "\\", else: "/"), flag)
      acc = put_glyph(acc, edge_row, child.col, "|", flag)

      lo = min(parent.col + sign, child.col - sign)
      hi = max(parent.col + sign, child.col - sign)

      Enum.reduce(lo..hi//1, acc, fn col, a -> put_glyph(a, edge_row, col, "-", flag) end)
    end
  end

  defp put_glyph({grid, edges}, row, col, glyph, flag) do
    row_map = Map.get(grid, row, %{})
    existing = Map.get(row_map, col)

    if existing == nil or rank(glyph) > rank(existing) do
      cell = %{col: col, glyph: glyph, kind: :edge, node_id: nil, flag: flag}
      {Map.put(grid, row, Map.put(row_map, col, glyph)), Map.put(edges, {row, col}, cell)}
    else
      {grid, edges}
    end
  end

  defp rank(glyph), do: Map.get(@glyph_rank, glyph, 0)

  defp overlay_nodes(grid, cells) do
    Enum.reduce(cells, grid, fn {_id, cell}, acc ->
      row_map = Map.get(acc, cell.row, %{})
      glyph = if cell.pinned, do: "◉", else: "●"
      Map.put(acc, cell.row, Map.put(row_map, cell.col, glyph))
    end)
  end

  defp grid_width(cells, edge_cells) do
    node_max = cells |> Map.values() |> Enum.map(& &1.col) |> Enum.max(fn -> 0 end)

    edge_max =
      edge_cells |> Map.values() |> Enum.map(& &1.col) |> Enum.max(fn -> 0 end)

    max(node_max, edge_max) + 1
  end

  defp row_glyphs(row, row_cells, grid, edge_cells) do
    glyphs = Map.get(grid, row, %{})

    node_cells =
      Enum.map(row_cells, fn {id, cell} ->
        %{
          col: cell.col,
          glyph: Map.get(glyphs, cell.col, if(cell.pinned, do: "◉", else: "●")),
          kind: :node,
          node_id: id,
          flag: cell.flag
        }
      end)

    edge_row_cells =
      edge_cells
      |> Enum.filter(fn {{r, _col}, _cell} -> r == row end)
      |> Enum.map(fn {_key, cell} -> cell end)

    (node_cells ++ edge_row_cells)
    |> Enum.sort_by(& &1.col)
  end

  defp row_marks(row_cells, nodes_out) do
    row_cells
    |> Enum.flat_map(fn {id, _cell} -> get_in(nodes_out, [id, :marks]) || [] end)
    |> Enum.uniq()
    |> Enum.sort_by(fn
      :current -> 0
      :preview -> 1
      :pinned -> 2
      _ -> 3
    end)
  end

  defp marks(id, node, default_id, preview_id, pointer) do
    []
    |> add_mark(id == default_id, :current)
    |> add_mark(id == pointer and id != default_id, :current)
    |> add_mark(id == preview_id, :preview)
    |> add_mark(node["pinned"] == true, :pinned)
  end

  defp add_mark(marks, true, mark), do: marks ++ [mark]
  defp add_mark(marks, _false, _mark), do: marks

  defp primary_flag(node) do
    flags = MapSet.new(node_flags(node))
    Enum.find(@flag_priority, &MapSet.member?(flags, &1))
  end

  defp node_flags(node) do
    case node["flags"] do
      flags when is_list(flags) -> Enum.filter(flags, &is_binary/1)
      _ -> []
    end
  end

  defp node_parents(node) do
    case node["parents"] do
      parents when is_list(parents) -> Enum.filter(parents, &is_binary/1)
      _ -> []
    end
  end

  defp score(from, cell, :down) when cell.row > from.row,
    do: (cell.row - from.row) * 1000 + abs(cell.col - from.col)

  defp score(from, cell, :up) when cell.row < from.row,
    do: (from.row - cell.row) * 1000 + abs(cell.col - from.col)

  defp score(from, cell, :right) when cell.row == from.row and cell.col > from.col,
    do: cell.col - from.col

  defp score(from, cell, :left) when cell.row == from.row and cell.col < from.col,
    do: from.col - cell.col

  defp score(_from, _cell, _dir), do: nil

  defp trim_offset(_layout, _max_width, nil), do: 0

  defp trim_offset(layout, max_width, focus_id) do
    case Map.get(layout.nodes, focus_id) do
      nil ->
        0

      %{col: col} ->
        col
        |> Kernel.-(div(max_width, 2))
        |> max(0)
        |> min(max(layout.width - max_width, 0))
    end
  end
end
