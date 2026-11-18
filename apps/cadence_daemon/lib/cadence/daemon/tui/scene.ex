defmodule Cadence.Daemon.TUI.Scene do
  @moduledoc """
  Pure widget composition for the TUI.

  `scene/2` takes the app state and the frame dimensions and returns the
  `{widget, rect}` list ExRatatui draws. It performs no I/O and touches no
  process state, so a test can render it into a headless terminal and assert on
  `ExRatatui.get_buffer_content/1`.

  Layout: a DAG rail on the left, the selected node's header and diff on the
  right, one status line at the bottom, and a centered overlay for the picker,
  help, spawn input, proposals, and union mode.
  """

  alias ExRatatui.Frame
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Text
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.Block
  alias ExRatatui.Widgets.Clear
  alias ExRatatui.Widgets.Paragraph

  alias Cadence.Daemon.TUI.DAG

  # Right-hand gutter reserved for row marks, so a mark never wraps the rail.
  @mark_gutter 12

  @flag_colors %{
    "broken" => :red,
    "in-progress" => :yellow,
    "sandbox" => :magenta,
    "functioning" => :green
  }

  @help [
    {"h j k l / arrows", "move around the DAG"},
    {"Enter", "switch the session pointer to the selected node"},
    {"s", "spawn a session from the current node"},
    {"u", "union mode: Enter toggles a parent, S submits, Esc cancels"},
    {"p", "proposals: j/k selects, y copies the URL, Esc closes"},
    {"d / D", "node diff / docs diff for the selected node"},
    {"J / K", "scroll the diff down / up"},
    {"g", "queue docs sync for the selected node"},
    {"r", "refresh graph and projects"},
    {"q / Esc", "quit (Esc closes an overlay first)"}
  ]

  @doc """
  Composes the widgets for `state` into `frame`.

  Returns a list of `{widget, rect}` tuples. Overlay widgets come last, so a
  `Clear` plus the overlay paints over the base panes.
  """
  @spec scene(map(), Frame.t()) :: [{term(), Rect.t()}]
  def scene(state, %Frame{width: width, height: height}) do
    area = %Rect{x: 0, y: 0, width: max(width, 0), height: max(height, 0)}

    {main, status} =
      case Layout.split(area, :vertical, [{:fill, 1}, {:length, 1}]) do
        [main, status] -> {main, status}
        _ -> {area, %Rect{x: 0, y: 0, width: 0, height: 0}}
      end

    {rail, pane} =
      case Layout.split(main, :horizontal, [{:percentage, 40}, {:fill, 1}]) do
        [rail, pane] -> {rail, pane}
        _ -> {main, main}
      end

    [
      {rail_widget(state, rail), rail}
    ] ++
      pane_widgets(state, pane) ++
      [status_widget(state, status)] ++ overlay(state, area)
  end

  # -- rail ------------------------------------------------------------------

  defp rail_widget(state, rect) do
    title =
      case state.project do
        %{"slug" => slug} -> "DAG · #{slug}"
        %{"name" => name} -> "DAG · #{name}"
        _ -> "DAG"
      end

    block = %Block{
      title: title,
      titles: [
        %Block.Title{content: "◉ pinned", alignment: :right, style: dim_style()}
      ],
      borders: [:all],
      border_style: border_style(),
      padding: {0, 0, 0, 0}
    }

    %Paragraph{text: Text.new(rail_lines(state, rect)), block: block}
  end

  defp rail_lines(state, rect) do
    width = max(rect.width - 2, 1)
    # Keep the last two rows for the blank + flag legend.
    visible = max(rect.height - 2 - 2, 1)
    grid_width = max(width - @mark_gutter, 1)

    case state.layout do
      nil ->
        [dim_line(if(state.graph == nil, do: "loading graph…", else: "(empty graph)"))]

      layout ->
        layout
        |> DAG.trim(grid_width, state.cursor)
        |> visible_rows(visible, state.cursor)
        |> Enum.map(&row_line(&1, grid_width, state.cursor))
        |> append_legend()
    end
  end

  # A vertical viewport: large graphs scroll around the cursor instead of
  # walking it off-screen.
  defp visible_rows(layout, visible, cursor) do
    rows = layout.rows
    total = length(rows)

    if total <= visible do
      rows
    else
      row =
        case Map.get(layout.nodes, cursor) do
          %{row: row} -> row
          _ -> 0
        end

      offset = row |> Kernel.-(div(visible, 2)) |> max(0) |> min(total - visible)
      Enum.slice(rows, offset, visible)
    end
  end

  defp append_legend(lines) do
    legend = [
      span("broken", %Style{fg: :red}),
      span("  in-progress", %Style{fg: :yellow}),
      span("  sandbox", %Style{fg: :magenta}),
      span("  functioning", %Style{fg: :green})
    ]

    lines ++ [blank_line(), Line.new(legend)]
  end

  defp blank_line, do: Line.new([Span.new("")])

  defp row_line(row, width, cursor) do
    if row.cells == [] do
      if row.break do
        Line.new([span(String.duplicate("╌", width), dim_style())])
      else
        Line.new([Span.new("")])
      end
    else
      # One mark per row keeps it inside the gutter; pinned is already the ◉
      # glyph, so the words are ordered current > preview > pinned.
      mark =
        cond do
          :current in row.marks -> "◀ current"
          :preview in row.marks -> "◀ preview"
          :pinned in row.marks -> "◉ pinned"
          true -> nil
        end

      spans = row_spans(row.cells, width, cursor)

      if mark do
        Line.new(spans ++ [span(String.pad_trailing(mark, @mark_gutter), dim_style())])
      else
        Line.new(spans)
      end
    end
  end

  defp row_spans(cells, width, cursor) do
    {spans, used} =
      cells
      |> Enum.sort_by(& &1.col)
      |> Enum.reduce({[], 0}, fn cell, {acc, col} ->
        gap = max(cell.col - col, 0)
        acc = if gap > 0, do: [span(:binary.copy(" ", gap), dim_style()) | acc], else: acc

        [span(cell.glyph, cell_style(cell, cursor)) | acc]
        |> then(&{&1, cell.col + 1})
      end)

    tail = max(width - used, 0)
    spans = if tail > 0, do: [span(:binary.copy(" ", tail), dim_style()) | spans], else: spans
    Enum.reverse(spans)
  end

  defp cell_style(%{kind: :edge}, _cursor), do: %Style{fg: :dark_gray}

  defp cell_style(cell, cursor) do
    base = %Style{fg: Map.get(@flag_colors, cell.flag, :gray)}

    cond do
      cell.node_id == cursor -> %{base | modifiers: [:bold, :reversed]}
      cell.glyph == "◉" -> %{base | modifiers: [:bold]}
      true -> base
    end
  end

  # -- node pane -------------------------------------------------------------

  defp pane_widgets(state, rect) do
    node = selected_node(state)

    {header_rect, diff_rect} =
      case Layout.split(rect, :vertical, [{:length, 6}, {:fill, 1}]) do
        [header, diff] -> {header, diff}
        _ -> {rect, %Rect{x: rect.x, y: rect.y, width: rect.width, height: 0}}
      end

    [
      header_widget(state, node, header_rect),
      diff_widget(state, node, diff_rect)
    ]
  end

  defp header_widget(state, node, rect) do
    block = %Block{
      title: header_title(state, node),
      borders: [:all],
      border_style: border_style()
    }

    {%Paragraph{text: Text.new(header_lines(node)), block: block}, rect}
  end

  defp header_title(_state, nil), do: "node"

  defp header_title(state, node) do
    case state.diff_kind do
      :docs -> "docs · #{short(node["git_commit_sha"])}"
      _ -> "node · #{short(node["git_commit_sha"])}"
    end
  end

  defp header_lines(nil), do: [Line.new([span("no node selected", dim_style())])]

  defp header_lines(node) do
    flags =
      case node["flags"] || [] do
        [] -> "no flags"
        flags -> Enum.join(flags, ", ")
      end

    docs = "docs #{node["docs_state"] || "unknown"}"

    marks =
      [
        if(node["pinned"] == true, do: "pinned"),
        docs
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    [
      Line.new([span(node["message"] || "(no message)", %Style{modifiers: [:bold]})]),
      Line.new([
        span(short(node["git_commit_sha"]), %Style{fg: :cyan}),
        span("  " <> (node["created_at"] || ""), dim_style())
      ]),
      Line.new([span(flags, %Style{fg: :gray}), span("  " <> marks, dim_style())]),
      Line.new([span("parents: " <> parent_summary(node), dim_style())])
    ]
  end

  defp parent_summary(%{"parents" => parents}) when is_list(parents) and parents != [] do
    parents |> Enum.map(&short/1) |> Enum.join(", ")
  end

  defp parent_summary(_node), do: "(root)"

  defp diff_widget(state, _node, rect) do
    block = %Block{
      title: diff_title(state),
      borders: [:all],
      border_style: border_style()
    }

    paragraph = %Paragraph{
      text: Text.new(diff_lines(state)),
      block: block,
      scroll: {max(state.diff_scroll, 0), 0}
    }

    {paragraph, rect}
  end

  defp diff_title(%{diff_kind: :docs}), do: "docs diff"
  defp diff_title(_state), do: "diff"

  defp diff_lines(state) do
    case {state.diff_kind, state.diff} do
      {_kind, nil} -> [dim_line("press d for the node diff, D for the docs diff")]
      {_kind, []} -> [dim_line("(no changes)")]
      {_kind, lines} -> Enum.map(lines, &diff_line/1)
    end
  end

  defp diff_line(%{kind: :file, text: text}) do
    Line.new([span(text, %Style{fg: :cyan, modifiers: [:bold]})])
  end

  defp diff_line(%{kind: :add, text: text}), do: Line.new([span(text, %Style{fg: :green})])
  defp diff_line(%{kind: :del, text: text}), do: Line.new([span(text, %Style{fg: :red})])
  defp diff_line(%{kind: :ctx, text: text}), do: Line.new([span(text, %Style{fg: :gray})])
  defp diff_line(%{kind: :skip, text: text}), do: Line.new([span(text, dim_style())])
  defp diff_line(%{kind: :note, text: text}), do: Line.new([span(text, %Style{fg: :yellow})])
  defp diff_line(line), do: Line.new([span(to_string(line), dim_style())])

  # -- status bar ------------------------------------------------------------

  defp status_widget(state, rect) do
    {%Paragraph{text: Text.new(status_lines(state))}, rect}
  end

  defp status_lines(state) do
    project =
      case state.project do
        %{"slug" => slug} -> slug
        _ -> "no project"
      end

    pointer =
      case get_in(state.graph, ["session", "session_pointer"]) do
        p when is_binary(p) ->
          short(p)

        _ ->
          case selected_node(state) do
            nil -> "-"
            node -> short(node["git_commit_sha"])
          end
      end

    parts = [
      span("[#{project}]", %Style{fg: :cyan}),
      span(" session #{pointer}", dim_style()),
      reachability(state),
      busy(state),
      span("  " <> state.status.text, status_style(state.status.kind))
    ]

    [Line.new(parts)]
  end

  defp reachability(%{reachable: true}), do: span("  reachable", %Style{fg: :green})
  defp reachability(%{reachable: false}), do: span("  unreachable", %Style{fg: :red})
  defp reachability(_state), do: span("  connecting", dim_style())

  defp busy(%{busy: nil}), do: span("", dim_style())
  defp busy(%{busy: %{label: label}}), do: span("  ⏳ " <> label, %Style{fg: :yellow})

  defp status_style(:error), do: %Style{fg: :red, modifiers: [:bold]}
  defp status_style(:ok), do: %Style{fg: :green}
  defp status_style(:warn), do: %Style{fg: :yellow}
  defp status_style(_kind), do: %Style{}

  # -- overlays --------------------------------------------------------------

  defp overlay(%{mode: :normal}, _area), do: []
  defp overlay(%{mode: :help}, area), do: help_overlay(area)
  defp overlay(%{mode: :projects} = state, area), do: picker_overlay(state, area)
  defp overlay(%{mode: :proposals} = state, area), do: proposals_overlay(state, area)
  defp overlay(%{mode: :spawn} = state, area), do: spawn_overlay(state, area)
  defp overlay(%{mode: :union} = state, area), do: union_overlay(state, area)
  defp overlay(_state, _area), do: []

  defp help_overlay(area) do
    lines =
      Enum.map(@help, fn {key, description} ->
        Line.new([
          span(String.pad_trailing(key, 16), %Style{fg: :cyan, modifiers: [:bold]}),
          span(description)
        ])
      end)

    overlay_box("help · press ? or Esc to close", lines, area, 68, length(@help) + 4)
  end

  defp picker_overlay(state, area) do
    lines =
      case state.projects do
        [] ->
          [dim_line("no projects registered with this daemon")]

        projects ->
          projects
          |> Enum.with_index()
          |> Enum.map(fn {project, index} ->
            marker = if index == state.picker_index, do: "▶ ", else: "  "
            name = project["slug"] || project["name"] || project["id"]

            Line.new([
              span(
                marker,
                if(index == state.picker_index, do: %Style{fg: :cyan}, else: dim_style())
              ),
              span(
                to_string(name),
                if(index == state.picker_index, do: %Style{modifiers: [:bold]}, else: %Style{})
              )
            ])
          end)
      end

    overlay_box(
      "projects · Enter selects, Esc quits",
      lines,
      area,
      56,
      length(lines) + 4
    )
  end

  defp proposals_overlay(state, area) do
    lines =
      case state.proposals do
        [] ->
          [dim_line("no union proposals recorded for this project")]

        proposals ->
          proposals
          |> Enum.with_index()
          |> Enum.flat_map(fn {proposal, index} ->
            marker = if index == state.picker_index, do: "▶ ", else: "  "

            label =
              "#{proposal["kind"] || "?"} · #{proposal["status"] || "?"} · #{age(proposal["age_seconds"])}"

            [
              Line.new([
                span(
                  marker,
                  if(index == state.picker_index, do: %Style{fg: :cyan}, else: dim_style())
                ),
                span(label, %Style{modifiers: [:bold]}),
                span("  " <> (proposal["url"] || proposal["token"] || ""), dim_style())
              ])
            ]
          end)
      end

    overlay_box(
      "proposals · j/k selects, y copies the URL, Esc closes",
      lines,
      area,
      78,
      length(lines) + 4
    )
  end

  defp spawn_overlay(state, area) do
    lines = [
      Line.new([
        span("name: ", %Style{fg: :cyan}),
        span(state.input),
        span("█", %Style{fg: :cyan})
      ]),
      blank_line(),
      dim_line("Enter spawns from the current node, Esc cancels")
    ]

    overlay_box("spawn session", lines, area, 60, 7)
  end

  defp union_overlay(state, area) do
    count = length(state.union_ids)

    lines = [
      Line.new([
        span("#{count} parent(s) selected", %Style{modifiers: [:bold]})
      ]),
      dim_line("Enter toggles the focused node, S submits, Esc cancels"),
      dim_line("the first parent is the diff base; 2 to 8 parents")
    ]

    lines =
      lines ++
        case state.union_ids do
          [] ->
            [blank_line(), dim_line("(nothing selected yet)")]

          ids ->
            [
              blank_line()
              | Enum.map(ids, fn id -> Line.new([span("• " <> short(id), %Style{fg: :cyan})]) end)
            ]
        end

    overlay_box("union", lines, area, 64, length(lines) + 4)
  end

  defp overlay_box(title, lines, area, width, height) do
    height = max(min(height, area.height), 3)
    rect = centered(area, width, height)

    block = %Block{
      title: title,
      borders: [:all],
      border_style: %Style{fg: :cyan},
      style: %Style{bg: :black}
    }

    [
      {%Clear{}, rect},
      {%Paragraph{text: Text.new(lines), block: block}, rect}
    ]
  end

  defp centered(area, width, height) do
    width = min(width, area.width)
    height = min(height, area.height)

    %Rect{
      x: area.x + div(max(area.width - width, 0), 2),
      y: area.y + div(max(area.height - height, 0), 2),
      width: width,
      height: height
    }
  end

  # -- shared helpers --------------------------------------------------------

  defp selected_node(%{graph: nil}), do: nil
  defp selected_node(%{cursor: nil}), do: nil

  defp selected_node(%{graph: graph, cursor: cursor}) do
    Enum.find(graph["nodes"] || [], &(&1["id"] == cursor))
  end

  defp short(nil), do: "-"
  defp short(value) when is_binary(value) and byte_size(value) > 8, do: String.slice(value, 0, 8)
  defp short(value), do: to_string(value)

  defp age(nil), do: "-"
  defp age(seconds) when is_integer(seconds) and seconds < 60, do: "#{seconds}s"
  defp age(seconds) when is_integer(seconds) and seconds < 3600, do: "#{div(seconds, 60)}m"
  defp age(seconds) when is_integer(seconds), do: "#{div(seconds, 3600)}h"
  defp age(_seconds), do: "-"

  defp span(content, style \\ %Style{}), do: Span.new(content, style: style)
  defp dim_line(text), do: Line.new([span(text, dim_style())])
  defp dim_style, do: %Style{fg: :dark_gray}
  defp border_style, do: %Style{fg: :dark_gray}
end
