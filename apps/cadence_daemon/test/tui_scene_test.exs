defmodule Cadence.Daemon.TUI.SceneTest do
  use ExUnit.Case, async: true

  alias Cadence.Daemon.TUI.DAG
  alias Cadence.Daemon.TUI.Scene
  alias ExRatatui.Frame

  defp node(id, parents, depth, message, opts \\ []) do
    %{
      "id" => id,
      "git_commit_sha" => Keyword.get(opts, :sha, String.duplicate(id, 40)),
      "parents" => parents,
      "depth" => depth,
      "flags" => Keyword.get(opts, :flags, []),
      "pinned" => Keyword.get(opts, :pinned, false),
      "docs_state" => Keyword.get(opts, :docs_state, "current"),
      "created_at" => Keyword.get(opts, :created_at, "2026-01-01T00:00:00Z"),
      "message" => message
    }
  end

  defp graph do
    %{
      "nodes" => [
        node("a", [], 0, "Add the watcher"),
        node("b", ["a"], 1, "Add the picker", flags: ["functioning"], pinned: true)
      ],
      "edges" => [%{"from" => "a", "to" => "b"}],
      "default_node_id" => "b",
      "preview_node_id" => "b",
      "session" => %{"session_pointer" => "b"}
    }
  end

  defp base_state(overrides \\ %{}) do
    graph = graph()
    layout = DAG.layout(graph)

    Map.merge(
      %{
        project: %{"id" => "p1", "slug" => "demo", "name" => "Demo"},
        projects: [%{"id" => "p1", "slug" => "demo", "name" => "Demo"}],
        graph: graph,
        layout: layout,
        cursor: "b",
        diff: nil,
        diff_kind: :node,
        diff_scroll: 0,
        proposals: [],
        picker_index: 0,
        union_ids: [],
        input: "",
        mode: :normal,
        reachable: true,
        busy: nil,
        status: %{text: "ready", kind: :info}
      },
      overrides
    )
  end

  defp render(state, width \\ 110, height \\ 30) do
    terminal = ExRatatui.init_test_terminal(width, height)

    :ok =
      ExRatatui.draw(terminal, Scene.scene(state, %Frame{width: width, height: height}))

    ExRatatui.get_buffer_content(terminal)
  end

  test "scene/2 returns a widget and rect for each region" do
    widgets = Scene.scene(base_state(), %Frame{width: 100, height: 30})

    assert length(widgets) == 4

    assert Enum.all?(widgets, fn {_widget, rect} ->
             rect.width > 0 and rect.height > 0
           end)
  end

  test "renders the DAG rail, the selected node, the legend, and the status bar" do
    output = render(base_state())

    assert output =~ "DAG · demo"
    assert output =~ "Add the picker"
    assert output =~ "functioning"
    assert output =~ "ready"
    assert output =~ "session"
    assert output =~ "press d for the node diff"
    assert output =~ "◉ pinned"
    assert output =~ "current"
    # The rail is the glyph grid; node messages live in the node pane.
    assert output =~ "parents: a"
  end

  test "renders a node diff with kind prefixes" do
    diff = [
      %{kind: :file, text: "lib/a.ex  (modified)"},
      %{kind: :add, text: "+ new line"},
      %{kind: :del, text: "- old line"},
      %{kind: :note, text: "  … (truncated)"}
    ]

    output = render(base_state(%{diff: diff, diff_kind: :node}))

    assert output =~ "lib/a.ex  (modified)"
    assert output =~ "+ new line"
    assert output =~ "- old line"
    assert output =~ "(truncated)"
    assert output =~ "diff"
  end

  test "labels the docs diff and shows the docs state" do
    output =
      render(
        base_state(%{
          diff_kind: :docs,
          diff: [%{kind: :note, text: "no docs commit for this node"}]
        })
      )

    assert output =~ "docs diff"
    assert output =~ "no docs commit for this node"
    assert output =~ "docs current"
  end

  test "renders an explicit empty state before the graph loads" do
    output =
      render(
        base_state(%{
          graph: nil,
          layout: nil,
          cursor: nil,
          project: nil,
          reachable: nil,
          status: %{text: "connecting…", kind: :info}
        })
      )

    assert output =~ "loading graph…"
    assert output =~ "no project"
    assert output =~ "connecting"
    assert output =~ "no node selected"
  end

  test "shows a busy operation in the status bar" do
    output = render(base_state(%{busy: %{label: "waiting for meld…"}}))
    assert output =~ "waiting for meld…"
  end

  test "shows the unreachable state" do
    output =
      render(base_state(%{reachable: false, status: %{text: "daemon unreachable", kind: :error}}))

    assert output =~ "unreachable"
    assert output =~ "daemon unreachable"
  end

  test "help overlay lists the keys" do
    output = render(base_state(%{mode: :help}))

    assert output =~ "help · press ? or Esc to close"
    assert output =~ "switch the session pointer"
    assert output =~ "union mode"
    assert output =~ "copies the URL"
  end

  test "projects overlay lists projects and marks the picker row" do
    output =
      render(
        base_state(%{
          mode: :projects,
          projects: [
            %{"id" => "p1", "slug" => "demo"},
            %{"id" => "p2", "slug" => "other"}
          ],
          picker_index: 1
        })
      )

    assert output =~ "projects · Enter selects, Esc quits"
    assert output =~ "demo"
    assert output =~ "other"
    assert output =~ "▶"
  end

  test "projects overlay explains an empty project list" do
    output = render(base_state(%{mode: :projects, projects: []}))
    assert output =~ "no projects registered with this daemon"
  end

  test "proposals overlay lists kind, status, age, and URL" do
    output =
      render(
        base_state(%{
          mode: :proposals,
          proposals: [
            %{
              "kind" => "meld",
              "status" => "pending",
              "age_seconds" => 90,
              "url" => "https://example.test/proposals/abc"
            }
          ]
        })
      )

    assert output =~ "proposals · j/k selects, y copies the URL"
    assert output =~ "meld · pending · 1m"
    assert output =~ "https://example.test/proposals/abc"
  end

  test "proposals overlay handles an empty journal" do
    output = render(base_state(%{mode: :proposals, proposals: []}))
    assert output =~ "no union proposals recorded"
  end

  test "spawn overlay echoes the typed name" do
    output = render(base_state(%{mode: :spawn, input: "explore"}))
    assert output =~ "spawn session"
    assert output =~ "name: explore"
    assert output =~ "Enter spawns from the current node"
  end

  test "union overlay shows the selection count and ids" do
    output =
      render(
        base_state(%{
          mode: :union,
          union_ids: [
            "aaaaaaaa-0000-4000-8000-000000000000",
            "bbbbbbbb-0000-4000-8000-000000000000"
          ]
        })
      )

    assert output =~ "2 parent(s) selected"
    assert output =~ "Enter toggles the focused node"
    assert output =~ "aaaaaaaa"
    assert output =~ "bbbbbbbb"
  end

  test "union overlay explains an empty selection" do
    output = render(base_state(%{mode: :union, union_ids: []}))
    assert output =~ "nothing selected yet"
  end

  test "renders in a narrow terminal without crashing" do
    output = render(base_state(), 40, 12)

    assert output =~ "DAG"
    assert output =~ "demo"
    # The row mark lives in a reserved gutter and must not wrap the rail.
    assert output =~ "◀ current"
  end

  test "windows a tall rail around the selected node" do
    nodes =
      for i <- 0..24 do
        id = "n#{i}"

        %{
          "id" => id,
          "git_commit_sha" => String.pad_trailing(id, 40, "0"),
          "parents" => if(i == 0, do: [], else: ["n#{i - 1}"]),
          "depth" => i,
          "flags" => [],
          "pinned" => false,
          "docs_state" => "current",
          "created_at" => "2026-01-01T00:00:00Z",
          "message" => "node #{i}"
        }
      end

    graph = %{
      "nodes" => nodes,
      "edges" => for(i <- 1..24, do: %{"from" => "n#{i - 1}", "to" => "n#{i}"}),
      "default_node_id" => "n24",
      "session" => %{"session_pointer" => "n24"}
    }

    output =
      render(
        base_state(%{graph: graph, layout: DAG.layout(graph), cursor: "n24"}),
        110,
        24
      )

    # The cursor sits on the newest node at the bottom of a 49-row grid; the
    # rail must have scrolled it into view.
    assert output =~ "◀ current"
    assert output =~ "DAG · demo"
  end

  test "an unknown proposal age renders as a dash" do
    output =
      render(
        base_state(%{
          mode: :proposals,
          proposals: [%{"kind" => "meld", "status" => "pending", "age_seconds" => "nope"}]
        })
      )

    assert output =~ "meld · pending · -"
  end
end
