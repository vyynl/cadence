defmodule Cadence.Daemon.TUI do
  @moduledoc """
  ExRatatui application for the daemon terminal UI.

  A thin, keyboard-driven frontend with parity to the Neovim plugin: DAG
  navigation, switch, spawn, union, proposals, node/docs diffs, and docs sync.
  It is a pure socket client over `Cadence.Daemon.Client` (plan D2): no Repo, no
  GitStore, no server surface.

  All socket I/O runs asynchronously through `ExRatatui.Command.async/2`, so the
  renderer never blocks (a `POST /union` can take 180 seconds). Results arrive
  in `handle_info/2` and are applied only when they still match the current
  selection.

  The client is injected through the `:tui_client` application env (or the
  `:client` option) and the clipboard through `:copy`, so tests run without a
  TTY, a daemon, or a terminal clipboard.
  """

  use ExRatatui.App

  alias ExRatatui.Command
  alias ExRatatui.Event

  alias Cadence.Daemon.TUI.{Clipboard, Client, DAG, Diff, Scene}

  @default_refresh_ms 5_000

  @doc """
  Starts the TUI on the local transport and blocks until it quits.

  This is the entry point used by `mix cad.tui` and by the daemon release
  (`bin/cadence_daemon eval 'Cadence.Daemon.TUI.main()'`).
  """
  @spec main(keyword()) :: :ok
  def main(opts \\ []) do
    {:ok, _apps} = Application.ensure_all_started(:ex_ratatui)
    {:ok, pid} = start_link(opts)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  @impl true
  def mount(opts) do
    client =
      Keyword.get(opts, :client) || Application.get_env(:cadence_daemon, :tui_client, Client)

    refresh_ms = Keyword.get(opts, :refresh_ms, @default_refresh_ms)

    state = %{
      client: client,
      client_opts: Keyword.take(opts, [:socket_path, :fake]),
      copy: Keyword.get(opts, :copy, &Clipboard.copy/1),
      cwd: Keyword.get(opts, :cwd, File.cwd!()),
      project_arg: Keyword.get(opts, :project),
      project: nil,
      projects: [],
      graph: nil,
      layout: nil,
      cursor: nil,
      diff: nil,
      diff_kind: :node,
      diff_scroll: 0,
      proposals: [],
      picker_index: 0,
      union_ids: [],
      input: "",
      mode: :normal,
      reachable: nil,
      busy: nil,
      loaded?: false,
      status: %{text: "connecting…", kind: :info},
      refresh_ms: refresh_ms
    }

    commands = [Command.message(:refresh)]

    commands =
      if is_integer(refresh_ms) and refresh_ms > 0 do
        commands ++ [Command.send_after(refresh_ms, :tick)]
      else
        commands
      end

    {:ok, state, commands: commands}
  end

  @impl true
  def render(state, frame), do: Scene.scene(state, frame)

  @impl true
  def handle_event(%Event.Key{kind: kind} = key, state) when kind in [nil, "press", "repeat"] do
    handle_key(key, state)
  end

  def handle_event(_event, state), do: {:noreply, state}

  @impl true
  def handle_info(:tick, state) do
    {state, commands} = refresh(state)

    commands =
      if is_integer(state.refresh_ms) and state.refresh_ms > 0 do
        commands ++ [Command.send_after(state.refresh_ms, :tick)]
      else
        commands
      end

    {:noreply, state, commands: commands}
  end

  def handle_info(:refresh, state) do
    {state, commands} = refresh(state)
    {:noreply, state, commands: commands}
  end

  def handle_info({:health, result}, state) do
    case result do
      {:ok, _body} ->
        {:noreply, %{state | reachable: true}}

      {:error, error} ->
        {:noreply, state |> Map.put(:reachable, false) |> status(error_text(error), :error)}
    end
  end

  def handle_info({:projects, result}, state) do
    case result do
      {:ok, %{"projects" => projects}} when is_list(projects) ->
        state = apply_projects(state, projects)
        {state, commands} = load_graph(state)
        {:noreply, state, commands: commands}

      {:ok, _other} ->
        {:noreply, status(state, "unexpected /projects response", :error)}

      {:error, error} ->
        {:noreply, state |> Map.put(:reachable, false) |> status(error_text(error), :error)}
    end
  end

  def handle_info({:graph, result}, state) do
    case result do
      {:ok, graph} when is_map(graph) ->
        previous_cursor = state.cursor
        first_load? = not state.loaded?
        state = apply_graph(state, graph)

        state =
          if first_load?, do: status(%{state | loaded?: true}, "ready", :info), else: state

        if state.diff != nil and state.cursor == previous_cursor do
          # A background refresh; nodes are immutable, so the loaded diff stands.
          {:noreply, state}
        else
          {state, commands} = with_diff(state, state.diff_kind)
          {:noreply, state, commands: commands}
        end

      {:ok, _other} ->
        {:noreply, status(state, "unexpected /graph response", :error)}

      {:error, error} ->
        {:noreply, status(state, error_text(error), :error)}
    end
  end

  def handle_info({:diff, kind, node_id, result}, state) do
    if state.cursor == node_id and state.diff_kind == kind do
      lines =
        case result do
          {:ok, payload} -> Diff.format(payload, empty: empty_text(kind))
          {:error, error} -> Diff.format({:error, %{message: error_text(error)}})
        end

      {:noreply, %{state | diff: lines}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:switch, node_id, result}, state) do
    case result do
      {:ok, _body} ->
        state = state |> Map.put(:busy, nil) |> status("switched to #{short(node_id)}", :ok)
        {state, commands} = load_graph(state)
        {:noreply, state, commands: commands}

      {:error, error} ->
        {:noreply, state |> Map.put(:busy, nil) |> status(error_text(error), :error)}
    end
  end

  def handle_info({:spawn, result}, state) do
    case result do
      {:ok, %{"node" => node}} ->
        state =
          state
          |> Map.put(:busy, nil)
          |> status("spawned #{short(node["id"])}", :ok)

        {state, commands} = load_graph(state)
        {:noreply, state, commands: commands}

      {:ok, _body} ->
        {:noreply, state |> Map.put(:busy, nil) |> status("spawned", :ok)}

      {:error, error} ->
        {:noreply, state |> Map.put(:busy, nil) |> status(error_text(error), :error)}
    end
  end

  def handle_info({:union, result}, state) do
    case result do
      {:ok, body} ->
        url = body["proposal_url"] || body["proposal_token"] || "proposal created"
        state = state |> Map.put(:busy, nil) |> status("union submitted · #{url}", :ok)
        {state, commands} = load_proposals(state)
        {:noreply, state, commands: commands}

      {:error, error} ->
        {:noreply, state |> Map.put(:busy, nil) |> status(error_text(error), :error)}
    end
  end

  def handle_info({:docs_sync, result}, state) do
    case result do
      {:ok, %{"status" => "queued"} = body} ->
        {:noreply,
         state |> Map.put(:busy, nil) |> status("docs queued for #{short(body["node_id"])}", :ok)}

      {:ok, %{"status" => "skipped"} = body} ->
        {:noreply,
         state
         |> Map.put(:busy, nil)
         |> status("docs skipped: #{body["reason"] || "not needed"}", :warn)}

      {:ok, _body} ->
        {:noreply, state |> Map.put(:busy, nil) |> status("docs sync requested", :ok)}

      {:error, error} ->
        {:noreply, state |> Map.put(:busy, nil) |> status(error_text(error), :error)}
    end
  end

  def handle_info({:proposals, result}, state) do
    case result do
      {:ok, %{"proposals" => proposals}} when is_list(proposals) ->
        index = min(state.picker_index, max(length(proposals) - 1, 0))
        {:noreply, %{state | proposals: proposals, picker_index: index}}

      {:ok, _other} ->
        {:noreply, status(state, "unexpected /proposals response", :error)}

      {:error, error} ->
        {:noreply, status(state, error_text(error), :error)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- key handling ----------------------------------------------------------

  defp handle_key(key, %{mode: :help} = state) do
    if key.code in ["?", "esc", "q"],
      do: {:noreply, %{state | mode: :normal}},
      else: {:noreply, state}
  end

  defp handle_key(key, %{mode: :projects} = state), do: picker_key(key, state)
  defp handle_key(key, %{mode: :proposals} = state), do: proposals_key(key, state)
  defp handle_key(key, %{mode: :spawn} = state), do: spawn_key(key, state)
  defp handle_key(key, %{mode: :union} = state), do: union_key(key, state)
  defp handle_key(key, %{mode: :normal} = state), do: normal_key(key, state)

  defp handle_key(_key, state), do: {:noreply, state}

  defp normal_key(%{code: "q"}, state), do: {:stop, state}
  defp normal_key(%{code: "esc"}, state), do: {:stop, state}
  defp normal_key(%{code: "?"}, state), do: {:noreply, %{state | mode: :help}}
  defp normal_key(%{code: "r"}, state), do: refresh_event(state)
  defp normal_key(%{code: "enter"}, state), do: switch_node(state)

  defp normal_key(%{code: "s"}, state), do: spawn_prompt(state)

  defp normal_key(%{code: code} = key, state) when code in ["d", "D"] do
    kind = if code == "D" or shift?(key), do: :docs, else: :node
    {state, commands} = with_diff(state, kind)
    {:noreply, state, commands: commands}
  end

  defp normal_key(%{code: "g"}, state), do: docs_sync(state)
  defp normal_key(%{code: "p"}, state), do: open_proposals(state)
  defp normal_key(%{code: "u"}, state), do: open_union(state)

  defp normal_key(%{code: code} = key, state) when code in ["j", "J", "down"] do
    if code == "J" or shift?(key),
      do: scroll_diff(state, 1),
      else: move(state, :down)
  end

  defp normal_key(%{code: code} = key, state) when code in ["k", "K", "up"] do
    if code == "K" or shift?(key),
      do: scroll_diff(state, -1),
      else: move(state, :up)
  end

  defp normal_key(%{code: code}, state) when code in ["h", "left"], do: move(state, :left)
  defp normal_key(%{code: code}, state) when code in ["l", "right"], do: move(state, :right)
  defp normal_key(_key, state), do: {:noreply, state}

  defp picker_key(%{code: code}, state) when code in ["j", "down"] do
    index = min(state.picker_index + 1, max(length(state.projects) - 1, 0))
    {:noreply, %{state | picker_index: index}}
  end

  defp picker_key(%{code: code}, state) when code in ["k", "up"] do
    {:noreply, %{state | picker_index: max(state.picker_index - 1, 0)}}
  end

  defp picker_key(%{code: "enter"}, state) do
    case Enum.at(state.projects, state.picker_index) do
      nil ->
        status_event(state, "no project selected", :warn)

      project ->
        state = %{
          state
          | project: project,
            graph: nil,
            layout: nil,
            cursor: nil,
            diff: nil,
            diff_scroll: 0,
            mode: :normal
        }

        {state, commands} = load_graph(state)
        {:noreply, state, commands: commands}
    end
  end

  defp picker_key(%{code: "esc"}, state), do: {:stop, state}
  defp picker_key(_key, state), do: {:noreply, state}

  defp proposals_key(%{code: code}, state) when code in ["j", "down"] do
    index = min(state.picker_index + 1, max(length(state.proposals) - 1, 0))
    {:noreply, %{state | picker_index: index}}
  end

  defp proposals_key(%{code: code}, state) when code in ["k", "up"] do
    {:noreply, %{state | picker_index: max(state.picker_index - 1, 0)}}
  end

  defp proposals_key(%{code: "y"}, state) do
    case Enum.at(state.proposals, state.picker_index) do
      nil ->
        status_event(state, "no proposal selected", :warn)

      proposal ->
        case proposal["url"] do
          url when is_binary(url) and url != "" ->
            state.copy.(url)
            status_event(state, "copied #{url}", :ok)

          _ ->
            case proposal["token"] do
              token when is_binary(token) -> status_event(state, "no URL; token #{token}", :warn)
              _ -> status_event(state, "no proposal URL recorded", :warn)
            end
        end
    end
  end

  defp proposals_key(%{code: code}, state) when code in ["esc", "p", "q"] do
    {:noreply, %{state | mode: :normal}}
  end

  defp proposals_key(_key, state), do: {:noreply, state}

  defp spawn_key(%{code: "enter"}, %{busy: busy} = state) when not is_nil(busy),
    do: {:noreply, state}

  defp spawn_key(%{code: "enter"}, state) do
    case String.trim(state.input) do
      "" ->
        status_event(state, "spawn name cannot be empty", :warn)

      name ->
        case state.project do
          nil ->
            status_event(state, "no project selected", :warn)

          project ->
            command =
              Command.async(
                fn -> state.client.spawn(project["id"], name, state.client_opts) end,
                &{:spawn, normalize(&1)}
              )

            state =
              state
              |> Map.put(:mode, :normal)
              |> Map.put(:input, "")
              |> Map.put(:busy, %{label: "spawning…"})

            {:noreply, state, commands: [command]}
        end
    end
  end

  defp spawn_key(%{code: "esc"}, state) do
    {:noreply, %{state | mode: :normal, input: ""}}
  end

  defp spawn_key(%{code: "backspace"}, state) do
    {:noreply, %{state | input: String.slice(state.input, 0..-2//1)}}
  end

  defp spawn_key(%{code: code, modifiers: modifiers}, state) do
    if printable?(code, modifiers) do
      {:noreply, %{state | input: state.input <> code}}
    else
      {:noreply, state}
    end
  end

  defp union_key(%{code: "enter"}, state) do
    case state.cursor do
      nil ->
        status_event(state, "no node selected", :warn)

      id ->
        selected = state.union_ids

        cond do
          id in selected ->
            {:noreply, %{state | union_ids: List.delete(selected, id)}}

          length(selected) >= 8 ->
            status_event(state, "a union takes at most 8 parents", :warn)

          true ->
            {:noreply, %{state | union_ids: selected ++ [id]}}
        end
    end
  end

  defp union_key(%{code: code} = key, state) when code in ["s", "S"] do
    if code == "S" or shift?(key), do: submit_union(state), else: {:noreply, state}
  end

  defp union_key(%{code: "esc"}, state) do
    {:noreply, %{state | mode: :normal, union_ids: []}}
  end

  defp union_key(%{code: code} = key, state) do
    # Movement stays available while the union selection is open.
    cond do
      code in ["j", "down"] ->
        if shift?(key), do: scroll_diff(state, 1), else: move(state, :down)

      code in ["k", "up"] ->
        if shift?(key), do: scroll_diff(state, -1), else: move(state, :up)

      code in ["h", "left"] ->
        move(state, :left)

      code in ["l", "right"] ->
        move(state, :right)

      true ->
        {:noreply, state}
    end
  end

  # -- actions ---------------------------------------------------------------

  defp refresh(state) do
    commands = [
      Command.async(fn -> state.client.health(state.client_opts) end, &{:health, normalize(&1)}),
      Command.async(
        fn -> state.client.projects(state.client_opts) end,
        &{:projects, normalize(&1)}
      )
    ]

    {state, commands}
  end

  defp refresh_event(state) do
    {state, commands} = refresh(state)
    {:noreply, status(state, "refreshed", :info), commands: commands}
  end

  defp apply_projects(state, projects) do
    state = %{state | projects: projects, reachable: true}

    cond do
      state.project && Enum.any?(projects, &(&1["id"] == state.project["id"])) ->
        %{state | project: Enum.find(projects, &(&1["id"] == state.project["id"]))}

      project = find_project(projects, state.project_arg) ->
        select_project(state, project)

      project = find_project(projects, state.cwd) ->
        select_project(state, project)

      projects == [] ->
        status(state, "no projects registered with this daemon", :warn)

      state.mode == :projects ->
        # A refresh must not reset a picker the user is moving in.
        %{
          state
          | picker_index: min(state.picker_index, max(length(projects) - 1, 0))
        }

      state.mode == :normal ->
        %{state | mode: :projects, picker_index: 0}

      true ->
        state
    end
  end

  defp select_project(state, project) do
    if state.project && state.project["id"] == project["id"] do
      state
    else
      %{state | project: project, graph: nil, layout: nil, cursor: nil, diff: nil, diff_scroll: 0}
    end
  end

  defp find_project(_projects, nil), do: nil

  defp find_project(projects, value) when is_binary(value) do
    Enum.find(projects, fn project ->
      project["id"] == value or project["slug"] == value or
        (is_binary(project["work_dir"]) and Path.expand(project["work_dir"]) == Path.expand(value))
    end)
  end

  defp load_graph(%{project: nil} = state), do: {state, []}

  defp load_graph(state) do
    project = state.project

    command =
      Command.async(
        fn -> state.client.graph(project["id"], state.client_opts) end,
        &{:graph, normalize(&1)}
      )

    {state, [command]}
  end

  defp apply_graph(state, graph) do
    layout = DAG.layout(graph)
    preferred = state.cursor || graph["default_node_id"]
    cursor = DAG.default_id(layout, preferred)

    %{
      state
      | graph: graph,
        layout: layout,
        cursor: cursor,
        reachable: true,
        picker_index: min(state.picker_index, max(length(state.projects) - 1, 0))
    }
  end

  defp with_diff(%{cursor: nil} = state, _kind), do: {state, []}
  defp with_diff(%{project: nil} = state, _kind), do: {state, []}

  defp with_diff(state, kind) do
    project = state.project
    node_id = state.cursor

    fun = fn ->
      case kind do
        :docs -> state.client.docs_diff(project["id"], node_id, state.client_opts)
        _ -> state.client.diff(project["id"], node_id, state.client_opts)
      end
    end

    command = Command.async(fun, fn result -> {:diff, kind, node_id, normalize(result)} end)

    {%{state | diff_kind: kind, diff_scroll: 0}, [command]}
  end

  defp move(%{layout: nil} = state, _dir), do: {:noreply, state}

  defp move(state, dir) do
    case DAG.move(state.layout, state.cursor, dir) do
      nil ->
        {:noreply, state}

      id ->
        state = %{state | cursor: id, diff_scroll: 0}
        {state, commands} = with_diff(state, state.diff_kind)
        {:noreply, state, commands: commands}
    end
  end

  defp switch_node(%{busy: busy} = state) when not is_nil(busy), do: {:noreply, state}

  defp switch_node(state) do
    with %{} = project <- state.project,
         id when is_binary(id) <- state.cursor do
      command =
        Command.async(
          fn -> state.client.switch(project["id"], id, state.client_opts) end,
          fn result -> {:switch, id, normalize(result)} end
        )

      state = %{state | busy: %{label: "switching…"}}
      {:noreply, state, commands: [command]}
    else
      _ -> status_event(state, "select a node first", :warn)
    end
  end

  defp spawn_prompt(state) do
    if state.project do
      {:noreply, %{state | mode: :spawn, input: ""}}
    else
      status_event(state, "no project selected", :warn)
    end
  end

  defp open_union(state) do
    if state.project do
      {:noreply, %{state | mode: :union, union_ids: []}}
    else
      status_event(state, "no project selected", :warn)
    end
  end

  defp submit_union(%{busy: busy} = state) when not is_nil(busy), do: {:noreply, state}

  defp submit_union(state) do
    ids = state.union_ids

    cond do
      state.project == nil ->
        status_event(state, "no project selected", :warn)

      length(ids) < 2 ->
        status_event(state, "select at least 2 parents", :warn)

      true ->
        project = state.project

        command =
          Command.async(
            fn -> state.client.union(project["id"], ids, state.client_opts) end,
            &{:union, normalize(&1)}
          )

        # Close the selection at submit time. The request can run for 180 s, so
        # leaving the overlay open would let a late reply discard a new pick.
        state = %{state | busy: %{label: "waiting for meld…"}, mode: :normal, union_ids: []}
        {:noreply, state, commands: [command]}
    end
  end

  defp docs_sync(%{busy: busy} = state) when not is_nil(busy), do: {:noreply, state}

  defp docs_sync(state) do
    with %{} = project <- state.project,
         id when is_binary(id) <- state.cursor do
      command =
        Command.async(
          fn -> state.client.docs_sync(project["id"], id, state.client_opts) end,
          &{:docs_sync, normalize(&1)}
        )

      state = %{state | busy: %{label: "queueing docs…"}}
      {:noreply, state, commands: [command]}
    else
      _ -> status_event(state, "select a node first", :warn)
    end
  end

  defp open_proposals(state) do
    if state.project do
      {state, commands} = load_proposals(state)
      {:noreply, %{state | mode: :proposals, picker_index: 0}, commands: commands}
    else
      status_event(state, "no project selected", :warn)
    end
  end

  defp load_proposals(%{project: nil} = state), do: {%{state | proposals: []}, []}

  defp load_proposals(state) do
    project = state.project

    command =
      Command.async(
        fn -> state.client.proposals(project["id"], state.client_opts) end,
        &{:proposals, normalize(&1)}
      )

    {state, [command]}
  end

  defp scroll_diff(state, delta) do
    max_scroll = max(length(state.diff || []) - 1, 0)
    offset = (state.diff_scroll + delta) |> max(0) |> min(max_scroll)
    {:noreply, %{state | diff_scroll: offset}}
  end

  # -- helpers ---------------------------------------------------------------

  # `Command.async/2` hands a crash to the mapper as `{:error, reason}`; keep
  # that shape and normalise anything unexpected so no handler has to guess.
  defp normalize({:ok, _} = ok), do: ok
  defp normalize({:error, %{status: _} = error}), do: {:error, error}

  defp normalize({:error, reason}),
    do: {:error, %{status: :invalid_response, message: error_text(reason)}}

  defp normalize(other), do: {:error, %{status: :invalid_response, message: error_text(other)}}

  defp error_text(%{message: message}) when is_binary(message), do: message
  defp error_text({:exception, message}), do: message
  defp error_text({:exit, reason}), do: "request task exited: #{inspect(reason)}"
  defp error_text({kind, reason}) when kind in [:throw, :error], do: "#{kind}: #{inspect(reason)}"
  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(reason), do: inspect(reason)

  defp status(state, text, kind), do: %{state | status: %{text: text, kind: kind}}

  defp status_event(state, text, kind) do
    {:noreply, status(state, text, kind)}
  end

  defp empty_text(:docs), do: "(no docs changes)"
  defp empty_text(_kind), do: "(no changes)"

  defp shift?(%{code: code, modifiers: modifiers}) do
    "shift" in (modifiers || []) or
      (is_binary(code) and byte_size(code) == 1 and code =~ ~r/\A[A-Z]\z/)
  end

  defp shift?(_key), do: false

  @control_keys ~w(enter esc tab back_tab backspace delete insert up down left right
                   home end page_up page_down f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12
                   caps_lock scroll_lock num_lock print_screen pause menu keypad_begin)

  defp printable?(code, modifiers) when is_binary(code) do
    code != "" and code not in @control_keys and
      not Enum.any?(["ctrl", "alt", "super", "hyper", "meta"], &(&1 in modifiers)) and
      String.length(code) == 1
  end

  defp printable?(_code, _modifiers), do: false

  defp short(nil), do: "-"
  defp short(value) when is_binary(value) and byte_size(value) > 8, do: String.slice(value, 0, 8)
  defp short(value), do: to_string(value)
end
