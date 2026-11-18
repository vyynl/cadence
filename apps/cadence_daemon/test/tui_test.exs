defmodule Cadence.Daemon.TUITest do
  use ExUnit.Case, async: false

  import Cadence.Daemon.TestHelpers, only: [eventually: 1]

  alias Cadence.Daemon.TUI
  alias Cadence.Daemon.TUI.FakeClient
  alias ExRatatui.Event
  alias ExRatatui.Runtime

  defp project do
    %{"id" => "p1", "slug" => "demo", "name" => "Demo", "work_dir" => "/work/demo"}
  end

  defp graph do
    %{
      "nodes" => [
        %{
          "id" => "a",
          "git_commit_sha" => String.duplicate("a", 40),
          "parents" => [],
          "depth" => 0,
          "flags" => [],
          "pinned" => false,
          "docs_state" => "current",
          "created_at" => "2026-01-01T00:00:00Z",
          "message" => "root node"
        },
        %{
          "id" => "b",
          "git_commit_sha" => String.duplicate("b", 40),
          "parents" => ["a"],
          "depth" => 1,
          "flags" => ["functioning"],
          "pinned" => true,
          "docs_state" => "pending",
          "created_at" => "2026-01-02T00:00:00Z",
          "message" => "child node"
        }
      ],
      "edges" => [%{"from" => "a", "to" => "b"}],
      "default_node_id" => "b",
      "preview_node_id" => "b",
      "session" => %{"session_pointer" => "b"}
    }
  end

  defp diff_payload(node_id) do
    %{
      "node_id" => node_id,
      "files" => [
        %{
          "path" => "lib/#{node_id}.ex",
          "status" => "modified",
          "lines" => [
            %{"kind" => "ctx", "text" => "context"},
            %{"kind" => "add", "text" => "line"},
            %{"kind" => "del", "text" => "old"}
          ]
        }
      ]
    }
  end

  defp start_tui(agent, responses \\ %{}, opts \\ []) do
    test_pid = self()

    Agent.update(agent, fn _ ->
      Map.merge(
        %{
          notify: test_pid,
          health: {:ok, %{"status" => "ok"}},
          projects: {:ok, %{"projects" => [project()]}},
          graph: {:ok, graph()},
          diff: fn [_project_id, node_id] -> {:ok, diff_payload(node_id)} end,
          docs_diff: fn [_project_id, node_id] -> {:ok, diff_payload(node_id)} end,
          proposals: {:ok, %{"proposals" => []}}
        },
        responses
      )
    end)

    defaults = [
      name: nil,
      client: FakeClient,
      fake: agent,
      refresh_ms: nil,
      cwd: "/work/demo",
      copy: fn text -> send(test_pid, {:copied, text}) end,
      test_mode: {120, 40}
    ]

    start_supervised!({TUI, Keyword.merge(defaults, opts)})
  end

  defp state(pid), do: :sys.get_state(pid).user_state

  defp press(pid, code, modifiers \\ []) do
    Runtime.inject_event(pid, %Event.Key{code: code, kind: "press", modifiers: modifiers})
  end

  setup do
    {:ok, agent} = Agent.start_link(fn -> %{notify: self()} end)
    %{agent: agent}
  end

  test "mount loads health, projects, and the graph, then selects the default node", %{
    agent: agent
  } do
    pid = start_tui(agent)

    eventually(fn ->
      state = state(pid)
      state.project["slug"] == "demo" and state.cursor == "b" and state.graph != nil
    end)

    state = state(pid)
    assert state.reachable == true
    assert state.layout.height == 3
    assert state.mode == :normal
  end

  test "j/k move the cursor and reload the diff", %{agent: agent} do
    pid = start_tui(agent)
    eventually(fn -> state(pid).cursor == "b" end)

    press(pid, "k")

    eventually(fn -> state(pid).cursor == "a" end)
    assert_receive {:fake_call, :diff, ["p1", "a"]}, 1_000

    eventually(fn -> state(pid).diff != nil end)

    assert [
             %{kind: :file, text: "lib/a.ex  (modified)"},
             %{kind: :ctx, text: "  context"},
             %{kind: :add, text: "+ line"},
             %{kind: :del, text: "- old"}
           ] =
             state(pid).diff
  end

  test "movement clamps at the edges", %{agent: agent} do
    pid = start_tui(agent)
    eventually(fn -> state(pid).cursor == "b" end)

    press(pid, "j")
    press(pid, "l")
    assert state(pid).cursor == "b"

    press(pid, "k")
    assert state(pid).cursor == "a"

    press(pid, "k")
    press(pid, "h")
    assert state(pid).cursor == "a"
  end

  test "Enter switches the session pointer to the selected node", %{agent: agent} do
    pid = start_tui(agent, %{switch: {:ok, %{"session_pointer" => "b"}}})
    eventually(fn -> state(pid).cursor == "b" end)

    press(pid, "enter")

    assert_receive {:fake_call, :switch, ["p1", "b"]}, 1_000
    eventually(fn -> state(pid).status.text == "switched to b" end)
    assert state(pid).busy == nil
  end

  test "s opens the spawn prompt, typing builds the name, and Enter posts it", %{agent: agent} do
    pid =
      start_tui(agent, %{
        spawn: {:ok, %{"node" => %{"id" => "c", "git_commit_sha" => String.duplicate("c", 40)}}}
      })

    eventually(fn -> state(pid).cursor == "b" end)

    press(pid, "s")
    assert state(pid).mode == :spawn

    for char <- ["e", "x", "p"], do: press(pid, char)
    assert state(pid).input == "exp"

    press(pid, "enter")

    assert_receive {:fake_call, :spawn, ["p1", "exp"]}, 1_000
    eventually(fn -> state(pid).status.text == "spawned c" end)
    assert state(pid).mode == :normal
    assert state(pid).input == ""
  end

  test "Esc cancels the spawn prompt and backspace edits it", %{agent: agent} do
    pid = start_tui(agent)
    eventually(fn -> state(pid).cursor == "b" end)

    press(pid, "s")
    press(pid, "a")
    press(pid, "b")
    press(pid, "backspace")
    assert state(pid).input == "a"

    press(pid, "esc")
    assert state(pid).mode == :normal
    assert state(pid).input == ""
  end

  test "an empty spawn name is refused without a request", %{agent: agent} do
    pid = start_tui(agent)
    eventually(fn -> state(pid).cursor == "b" end)

    press(pid, "s")
    press(pid, "enter")

    assert state(pid).status.text == "spawn name cannot be empty"
    refute_receive {:fake_call, :spawn, _}, 100
  end

  test "union mode toggles parents and shift+s submits", %{agent: agent} do
    pid =
      start_tui(agent, %{
        union:
          {:ok,
           %{"proposal_token" => "tok", "proposal_url" => "https://example.test/proposals/tok"}}
      })

    eventually(fn -> state(pid).cursor == "b" end)

    press(pid, "u")
    assert state(pid).mode == :union

    press(pid, "enter")
    assert state(pid).union_ids == ["b"]

    press(pid, "k")
    eventually(fn -> state(pid).cursor == "a" end)
    press(pid, "enter")
    assert state(pid).union_ids == ["b", "a"]

    # Toggling the same node removes it.
    press(pid, "enter")
    assert state(pid).union_ids == ["b"]
    press(pid, "enter")
    assert state(pid).union_ids == ["b", "a"]

    press(pid, "S")

    assert_receive {:fake_call, :union, ["p1", ["b", "a"]]}, 1_000
    eventually(fn -> state(pid).status.text =~ "union submitted" end)
    assert state(pid).mode == :normal
    assert state(pid).union_ids == []
  end

  test "union submit closes the selection before the reply", %{agent: agent} do
    pid = start_tui(agent, %{union: {:ok, %{"proposal_token" => "tok"}}})
    eventually(fn -> state(pid).cursor == "b" end)

    press(pid, "u")
    press(pid, "enter")
    press(pid, "k")
    eventually(fn -> state(pid).cursor == "a" end)
    press(pid, "enter")

    assert state(pid).union_ids == ["b", "a"]
    assert state(pid).mode == :union

    press(pid, "S")

    # Cleared synchronously: a late reply can never discard a new selection.
    assert state(pid).mode == :normal
    assert state(pid).union_ids == []

    eventually(fn -> state(pid).status.text =~ "union submitted" end)
  end

  test "a union with fewer than two parents is refused", %{agent: agent} do
    pid = start_tui(agent)
    eventually(fn -> state(pid).cursor == "b" end)

    press(pid, "u")
    press(pid, "S")

    assert state(pid).status.text == "select at least 2 parents"
    refute_receive {:fake_call, :union, _}, 100
  end

  test "Esc leaves union mode and clears the selection", %{agent: agent} do
    pid = start_tui(agent)
    eventually(fn -> state(pid).cursor == "b" end)

    press(pid, "u")
    press(pid, "enter")
    press(pid, "esc")

    assert state(pid).mode == :normal
    assert state(pid).union_ids == []
  end

  test "p opens proposals and y copies the selected URL", %{agent: agent} do
    pid =
      start_tui(agent, %{
        proposals:
          {:ok,
           %{
             "proposals" => [
               %{
                 "kind" => "meld",
                 "status" => "pending",
                 "url" => "https://example.test/proposals/tok"
               }
             ]
           }}
      })

    eventually(fn -> state(pid).cursor == "b" end)

    press(pid, "p")

    eventually(fn -> state(pid).proposals != [] end)
    assert state(pid).mode == :proposals

    press(pid, "y")
    assert_receive {:copied, "https://example.test/proposals/tok"}, 1_000
    assert state(pid).status.text =~ "copied"

    press(pid, "esc")
    assert state(pid).mode == :normal
  end

  test "y without a URL reports the token instead", %{agent: agent} do
    pid = start_tui(agent, %{proposals: {:ok, %{"proposals" => [%{"token" => "tok123"}]}}})
    eventually(fn -> state(pid).cursor == "b" end)

    press(pid, "p")
    eventually(fn -> state(pid).mode == :proposals and state(pid).proposals != [] end)
    press(pid, "y")

    assert state(pid).status.text =~ "tok123"
    refute_receive {:copied, _}, 100
  end

  test "d loads the node diff and shift+d loads the docs diff", %{agent: agent} do
    pid = start_tui(agent)
    eventually(fn -> state(pid).cursor == "b" end)

    eventually(fn -> state(pid).diff != nil end)
    flush_fake_calls()

    press(pid, "d", ["shift"])

    assert_receive {:fake_call, :docs_diff, ["p1", "b"]}, 1_000
    eventually(fn -> state(pid).diff_kind == :docs and state(pid).diff != nil end)

    press(pid, "d")
    assert_receive {:fake_call, :diff, ["p1", "b"]}, 1_000
    eventually(fn -> state(pid).diff_kind == :node end)
  end

  test "J and K scroll the diff", %{agent: agent} do
    pid = start_tui(agent)
    eventually(fn -> state(pid).cursor == "b" and state(pid).diff != nil end)

    press(pid, "J")
    press(pid, "J")
    assert state(pid).diff_scroll == 2

    press(pid, "K")
    assert state(pid).diff_scroll == 1

    press(pid, "K")
    press(pid, "K")
    assert state(pid).diff_scroll == 0
  end

  test "g queues docs sync for the selected node", %{agent: agent} do
    pid =
      start_tui(agent, %{docs_sync: {:ok, %{"status" => "queued", "node_id" => "b"}}})

    eventually(fn -> state(pid).cursor == "b" end)

    press(pid, "g")

    assert_receive {:fake_call, :docs_sync, ["p1", "b"]}, 1_000
    eventually(fn -> state(pid).status.text == "docs queued for b" end)
    assert state(pid).busy == nil
  end

  test "a skipped docs sync reports the reason", %{agent: agent} do
    pid = start_tui(agent, %{docs_sync: {:ok, %{"status" => "skipped", "reason" => "no_schema"}}})
    eventually(fn -> state(pid).cursor == "b" end)

    press(pid, "g")

    eventually(fn -> state(pid).status.text == "docs skipped: no_schema" end)
  end

  test "daemon errors land in the status line", %{agent: agent} do
    pid =
      start_tui(agent, %{
        docs_sync: {:error, %{status: 503, message: "doc agent is not configured"}}
      })

    eventually(fn -> state(pid).cursor == "b" end)

    press(pid, "g")

    eventually(fn -> state(pid).status.text == "doc agent is not configured" end)
    assert state(pid).status.kind == :error
  end

  test "an unreachable daemon marks the session unreachable", %{agent: agent} do
    pid =
      start_tui(agent, %{
        health: {:error, %{status: :unreachable, message: "daemon unreachable"}},
        projects: {:error, %{status: :unreachable, message: "daemon unreachable"}}
      })

    eventually(fn -> state(pid).reachable == false end)
    assert state(pid).status.text =~ "daemon unreachable"
  end

  test "a failed async task is normalised into the status line", %{agent: agent} do
    pid = start_tui(agent, %{docs_sync: {:error, {:exception, "boom from the task"}}})
    eventually(fn -> state(pid).cursor == "b" end)

    press(pid, "g")

    eventually(fn -> state(pid).status.text == "boom from the task" end)
  end

  test "the project picker opens when no project matches and selects on Enter", %{agent: agent} do
    other = %{"id" => "p2", "slug" => "other", "name" => "Other", "work_dir" => "/work/other"}
    pid = start_tui(agent, %{projects: {:ok, %{"projects" => [other]}}})

    eventually(fn -> state(pid).mode == :projects end)
    assert state(pid).project == nil

    press(pid, "enter")

    eventually(fn -> state(pid).project["slug"] == "other" end)
    assert state(pid).mode == :normal
  end

  test "a refresh tick does not reset the project picker", %{agent: agent} do
    other = %{"id" => "p2", "slug" => "other", "work_dir" => "/work/other"}
    another = %{"id" => "p3", "slug" => "another", "work_dir" => "/work/another"}

    pid = start_tui(agent, %{projects: {:ok, %{"projects" => [other, another]}}}, refresh_ms: 25)

    eventually(fn -> state(pid).mode == :projects end)
    press(pid, "j")
    assert state(pid).picker_index == 1

    calls = length(Agent.get(agent, &(&1[:calls] || [])))

    eventually(fn ->
      length(Agent.get(agent, &(&1[:calls] || []))) > calls + 1
    end)

    assert state(pid).picker_index == 1
    assert state(pid).mode == :projects
  end

  test "the picker moves with j/k", %{agent: agent} do
    other = %{"id" => "p2", "slug" => "other", "name" => "Other", "work_dir" => "/work/other"}

    another = %{
      "id" => "p3",
      "slug" => "another",
      "name" => "Another",
      "work_dir" => "/work/another"
    }

    pid = start_tui(agent, %{projects: {:ok, %{"projects" => [other, another]}}})

    eventually(fn -> state(pid).mode == :projects end)

    press(pid, "j")
    assert state(pid).picker_index == 1
    press(pid, "k")
    assert state(pid).picker_index == 0
  end

  test "--project selects by slug", %{agent: agent} do
    pid = start_tui(agent, %{}, project: "demo")
    eventually(fn -> state(pid).project != nil end)
    assert state(pid).project["slug"] == "demo"
  end

  test "the working directory selects a project by work_dir", %{agent: agent} do
    pid = start_tui(agent, %{}, cwd: "/work/demo")
    eventually(fn -> state(pid).project != nil end)
    assert state(pid).project["slug"] == "demo"
  end

  test "r refreshes and the help overlay opens and closes", %{agent: agent} do
    pid = start_tui(agent)
    eventually(fn -> state(pid).cursor == "b" end)

    press(pid, "?")
    assert state(pid).mode == :help

    press(pid, "esc")
    assert state(pid).mode == :normal

    press(pid, "r")
    eventually(fn -> state(pid).status.text == "refreshed" end)
  end

  test "unknown keys and release events are ignored", %{agent: agent} do
    pid = start_tui(agent)
    eventually(fn -> state(pid).cursor == "b" end)

    press(pid, "z")
    assert state(pid).cursor == "b"

    Runtime.inject_event(pid, %Event.Key{code: "q", kind: "release"})
    assert Process.alive?(pid)
  end

  test "q stops the TUI", %{agent: agent} do
    pid = start_tui(agent)
    eventually(fn -> state(pid).cursor == "b" end)

    ref = Process.monitor(pid)

    try do
      press(pid, "q")
    catch
      :exit, _reason -> :ok
    end

    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
  end

  defp flush_fake_calls do
    receive do
      {:fake_call, _name, _args} -> flush_fake_calls()
    after
      0 -> :ok
    end
  end

  test "a periodic tick refreshes the state", %{agent: agent} do
    pid = start_tui(agent, %{}, refresh_ms: 25)

    eventually(fn -> state(pid).reachable == true end)

    # The tick reschedules itself; several /projects calls prove the loop runs.
    eventually(fn ->
      calls = Agent.get(agent, &(&1[:calls] || []))
      Enum.count(calls, fn {name, _args} -> name == :projects end) >= 3
    end)
  end

  test "an empty project list is reported and project-less keys warn", %{agent: agent} do
    pid = start_tui(agent, %{projects: {:ok, %{"projects" => []}}})

    eventually(fn -> state(pid).status.text == "no projects registered with this daemon" end)
    assert state(pid).project == nil

    for key <- ["s", "u", "p"] do
      press(pid, key)
      assert state(pid).status.text == "no project selected"
    end

    for key <- ["enter", "g"] do
      press(pid, key)
      assert state(pid).status.text == "select a node first"
    end

    press(pid, "d")
    assert state(pid).diff == nil
  end

  test "an empty graph leaves movement, diffs, and mutations inert", %{agent: agent} do
    empty = %{"nodes" => [], "edges" => [], "default_node_id" => nil}
    pid = start_tui(agent, %{graph: {:ok, empty}})

    eventually(fn -> state(pid).graph != nil end)
    assert state(pid).cursor == nil

    for key <- ["j", "k", "h", "l", "d", "enter", "g"] do
      press(pid, key)
      assert state(pid).cursor == nil
    end

    press(pid, "u")
    press(pid, "enter")
    assert state(pid).status.text == "no node selected"

    press(pid, "esc")
    assert state(pid).mode == :normal
  end

  test "a malformed graph payload is survived", %{agent: agent} do
    graph = {:ok, %{"nodes" => [nil, %{"id" => "x", "depth" => "0"}], "edges" => "nope"}}
    pid = start_tui(agent, %{graph: graph})

    eventually(fn -> state(pid).graph != nil end)

    assert Process.alive?(pid)
    assert state(pid).layout.nodes["x"].row == 0
  end

  test "graph and projects errors land in the status line", %{agent: agent} do
    pid =
      start_tui(agent, %{
        projects: {:error, %{status: 500, message: "projects broke"}}
      })

    eventually(fn -> state(pid).status.text == "projects broke" end)
    assert state(pid).reachable == false
  end

  test "a graph error after a successful project load is reported", %{agent: agent} do
    pid = start_tui(agent, %{graph: {:error, %{status: 500, message: "graph broke"}}})

    eventually(fn -> state(pid).status.text == "graph broke" end)
  end

  test "unexpected payloads are reported instead of crashing", %{agent: agent} do
    pid = start_tui(agent, %{projects: {:ok, "not a map"}})
    eventually(fn -> state(pid).status.text == "unexpected /projects response" end)
    assert Process.alive?(pid)
  end

  test "an unexpected graph payload is reported", %{agent: agent} do
    pid = start_tui(agent, %{graph: {:ok, "not a graph"}})
    eventually(fn -> state(pid).status.text == "unexpected /graph response" end)
  end

  test "an unexpected proposals payload is reported", %{agent: agent} do
    pid = start_tui(agent, %{proposals: {:ok, []}})
    eventually(fn -> state(pid).cursor == "b" end)

    press(pid, "p")
    eventually(fn -> state(pid).status.text == "unexpected /proposals response" end)
  end

  test "a diff error renders as a note in the pane", %{agent: agent} do
    pid = start_tui(agent, %{diff: {:error, %{status: 404, message: "commit not found"}}})

    eventually(fn -> state(pid).diff != nil end)
    assert state(pid).diff == [%{kind: :note, text: "commit not found"}]
  end

  test "switch, spawn, union, and proposals errors land in the status line", %{agent: agent} do
    responses = %{
      switch: {:error, %{status: 404, message: "node not found in project"}},
      spawn: {:error, %{status: 409, message: "no current node"}},
      union: {:error, %{status: 503, message: "sync is not configured"}}
    }

    pid = start_tui(agent, responses)
    eventually(fn -> state(pid).cursor == "b" end)

    press(pid, "enter")
    eventually(fn -> state(pid).status.text == "node not found in project" end)

    press(pid, "s")
    press(pid, "x")
    press(pid, "enter")
    eventually(fn -> state(pid).status.text == "no current node" end)

    press(pid, "u")
    press(pid, "enter")
    press(pid, "k")
    eventually(fn -> state(pid).cursor == "a" end)
    press(pid, "enter")
    press(pid, "S")
    eventually(fn -> state(pid).status.text == "sync is not configured" end)
  end

  test "a spawn response without a node still reports success", %{agent: agent} do
    pid = start_tui(agent, %{spawn: {:ok, %{}}})
    eventually(fn -> state(pid).cursor == "b" end)

    press(pid, "s")
    press(pid, "x")
    press(pid, "enter")

    eventually(fn -> state(pid).status.text == "spawned" end)
  end

  test "an unrecognised docs sync body still reports that it was requested", %{agent: agent} do
    pid = start_tui(agent, %{docs_sync: {:ok, %{}}})
    eventually(fn -> state(pid).cursor == "b" end)

    press(pid, "g")

    eventually(fn -> state(pid).status.text == "docs sync requested" end)
  end

  test "the proposals overlay moves, closes, and handles a missing selection", %{agent: agent} do
    proposals =
      {:ok,
       %{
         "proposals" => [
           %{"kind" => "meld", "status" => "pending", "token" => "one"},
           %{"kind" => "meld", "status" => "approved", "token" => "two"}
         ]
       }}

    pid = start_tui(agent, %{proposals: proposals})
    eventually(fn -> state(pid).cursor == "b" end)

    press(pid, "p")
    eventually(fn -> length(state(pid).proposals) == 2 end)

    press(pid, "j")
    assert state(pid).picker_index == 1
    press(pid, "j")
    assert state(pid).picker_index == 1
    press(pid, "k")
    assert state(pid).picker_index == 0
    press(pid, "k")
    assert state(pid).picker_index == 0

    # A key the overlay ignores.
    press(pid, "z")

    press(pid, "q")
    assert state(pid).mode == :normal
  end

  test "y without a selection or URL is reported", %{agent: agent} do
    pid = start_tui(agent, %{proposals: {:ok, %{"proposals" => [%{"token" => nil}]}}})
    eventually(fn -> state(pid).cursor == "b" end)

    press(pid, "p")
    eventually(fn -> state(pid).mode == :proposals and state(pid).proposals != [] end)

    press(pid, "y")
    assert state(pid).status.text == "no proposal URL recorded"
  end

  test "the picker quits on Esc", %{agent: agent} do
    other = %{"id" => "p2", "slug" => "other", "work_dir" => "/work/other"}
    pid = start_tui(agent, %{projects: {:ok, %{"projects" => [other]}}})
    eventually(fn -> state(pid).mode == :projects end)

    ref = Process.monitor(pid)

    try do
      press(pid, "esc")
    catch
      :exit, _reason -> :ok
    end

    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
  end

  test "unknown info messages are ignored", %{agent: agent} do
    pid = start_tui(agent)
    eventually(fn -> state(pid).cursor == "b" end)

    send(pid, :something_else)
    assert Process.alive?(pid)
    assert state(pid).cursor == "b"
  end

  test "a client result that is not a tagged tuple is normalised", %{agent: agent} do
    pid = start_tui(agent, %{docs_sync: "plain string"})
    eventually(fn -> state(pid).cursor == "b" end)

    press(pid, "g")

    eventually(fn -> state(pid).status.text == "plain string" end)
  end
end
