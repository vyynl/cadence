defmodule Cadence.Daemon.TestSyncServer do
  @moduledoc """
  Small stateful fake of the cloud sync API for daemon integration tests.

  State lives in an `Agent` so it works both when `Sync.sync/1` is called in the
  test process and when `SyncWorker` runs it in a task.
  """

  @doc "Starts a fake server state for `user_id`."
  def start(user_id) do
    Agent.start_link(fn ->
      %{
        user_id: user_id,
        projects: %{},
        nodes: [],
        preferences: %{},
        next_seq: 1,
        next_failure: nil
      }
    end)
  end

  @doc "Registers this fake server as the `Req.Test` plug under `name`."
  def stub(name, server) do
    Req.Test.stub(name, fn conn -> handle(server, conn) end)
  end

  @doc "Makes the next request fail with `status`/`body`."
  def fail_next(server, status, body \\ %{"error" => "forced failure"}) do
    Agent.update(server, &%{&1 | next_failure: {status, body}})
  end

  @doc "Seeds a remote wire node for pull tests."
  def seed_node(server, project_id, wire) do
    Agent.update(server, fn state ->
      entry = %{seq: state.next_seq, project_id: project_id, wire: wire}
      %{state | nodes: state.nodes ++ [entry], next_seq: state.next_seq + 1}
    end)
  end

  @doc "Returns the pushed wire nodes currently stored by the fake server."
  def nodes(server) do
    Agent.get(server, fn state -> Enum.map(state.nodes, & &1.wire) end)
  end

  @doc "Returns the stored server-side project map for `project_id`."
  def project(server, project_id) do
    Agent.get(server, fn state -> Map.get(state.projects, project_id) end)
  end

  @doc "Seeds stored preferences for `project_id` (string-keyed map)."
  def seed_preferences(server, project_id, preferences) do
    Agent.update(server, fn state ->
      %{state | preferences: Map.put(state.preferences, project_id, preferences)}
    end)
  end

  @doc "Returns the stored preferences for `project_id`, or the empty value."
  def preferences(server, project_id) do
    Agent.get(server, fn state ->
      Map.get(state.preferences, project_id) || empty_preferences()
    end)
  end

  defp handle(server, conn) do
    case take_failure(server) do
      {status, body} ->
        json(conn, status, body)

      nil ->
        route(server, conn)
    end
  end

  defp route(server, %{method: "GET", request_path: "/sync/me"} = conn) do
    state = Agent.get(server, & &1)
    json(conn, 200, %{user_id: state.user_id, email: "sync@example.com", name: "sync"})
  end

  defp route(server, %{method: "POST", request_path: "/sync/projects"} = conn) do
    project = conn.body_params["project"] || %{}

    with {:ok, id} <- project_id(project["id"]),
         name when is_binary(name) and name != "" <- project["name"],
         slug when is_binary(slug) and slug != "" <- project["slug"] do
      {status, stored} =
        Agent.get_and_update(server, fn state ->
          case Map.get(state.projects, id) do
            nil ->
              stored = %{"id" => id, "name" => name, "slug" => slug, "owner_id" => state.user_id}
              {{201, stored}, %{state | projects: Map.put(state.projects, id, stored)}}

            existing ->
              {{200, existing}, state}
          end
        end)

      json(conn, status, %{project: stored})
    else
      _ -> json(conn, 422, %{"error" => "invalid project"})
    end
  end

  defp route(server, %{method: "POST", request_path: "/sync/nodes"} = conn) do
    nodes = conn.body_params["nodes"] || []

    with [project_id] <- nodes |> Enum.map(&get_in(&1, ["metadata", "project_id"])) |> Enum.uniq(),
         true <- known_project?(server, project_id) do
      mappings =
        Agent.get_and_update(server, fn state ->
          {state, mappings} =
            Enum.reduce(nodes, {state, []}, fn node, {state, mappings} ->
              id = node["local_id"]
              metadata = node["metadata"] || %{}
              wire = Map.merge(metadata, %{"id" => id, "created_by" => state.user_id})
              wire = Map.put(wire, "git_objects", node["git_objects"] || [])

              state =
                if Enum.any?(state.nodes, &(&1.wire["id"] == id)) do
                  state
                else
                  entry = %{seq: state.next_seq, project_id: metadata["project_id"], wire: wire}
                  %{state | nodes: state.nodes ++ [entry], next_seq: state.next_seq + 1}
                end

              {state, [%{"local_id" => id, "cloud_id" => id} | mappings]}
            end)

          {Enum.reverse(mappings), state}
        end)

      json(conn, 200, %{mappings: mappings})
    else
      [] -> json(conn, 422, %{"error" => "empty batch"})
      false -> json(conn, 404, %{"error" => "project not found"})
      _ -> json(conn, 422, %{"error" => "mixed projects"})
    end
  end

  defp route(server, %{method: "POST", request_path: "/sync/preferences"} = conn) do
    params = conn.body_params
    project_id = params["project_id"]

    with true <- known_project?(server, project_id),
         {:ok, incoming} <- parse_version(params["updated_at"]) do
      stored =
        Agent.get_and_update(server, fn state ->
          current = Map.get(state.preferences, project_id) || empty_preferences()

          case parse_version(current["updated_at"]) do
            {:ok, nil} ->
              {new_preferences(params),
               %{
                 state
                 | preferences: Map.put(state.preferences, project_id, new_preferences(params))
               }}

            {:ok, current_version} ->
              if DateTime.compare(incoming, current_version) == :gt do
                updated = new_preferences(params)
                {updated, %{state | preferences: Map.put(state.preferences, project_id, updated)}}
              else
                {current, state}
              end

            :error ->
              {current, state}
          end
        end)

      json(conn, 200, %{preferences: stored})
    else
      false -> json(conn, 404, %{"error" => "project not found"})
      :error -> json(conn, 422, %{"error" => "invalid updated_at"})
    end
  end

  defp route(server, %{method: "GET", request_path: "/sync/nodes"} = conn) do
    project_id = conn.query_params["project_id"]
    since = parse_since(conn.query_params["since"])

    if known_project?(server, project_id) do
      {nodes, cursor, preferences} =
        Agent.get(server, fn state ->
          selected =
            state.nodes
            |> Enum.filter(&(&1.project_id == project_id and &1.seq > since))
            |> Enum.sort_by(& &1.seq)

          cursor =
            case selected do
              [] -> since
              _ -> List.last(selected).seq
            end

          preferences = Map.get(state.preferences, project_id) || empty_preferences()

          {Enum.map(selected, & &1.wire), cursor, preferences}
        end)

      json(conn, 200, %{
        nodes: nodes,
        cursor: Integer.to_string(cursor),
        preferences: preferences
      })
    else
      json(conn, 404, %{"error" => "project not found"})
    end
  end

  defp route(_server, conn) do
    json(conn, 404, %{"error" => "not found"})
  end

  defp take_failure(server) do
    Agent.get_and_update(server, fn state ->
      {state.next_failure, %{state | next_failure: nil}}
    end)
  end

  defp known_project?(server, project_id) do
    Agent.get(server, fn state -> Map.has_key?(state.projects, project_id) end)
  end

  defp project_id(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> :error
    end
  end

  defp empty_preferences do
    %{"active_heads" => [], "session_pointer" => nil, "updated_at" => nil}
  end

  defp new_preferences(params) do
    %{
      "active_heads" => params["active_heads"] || [],
      "session_pointer" => params["session_pointer"],
      "updated_at" => params["updated_at"]
    }
  end

  defp parse_version(nil), do: {:ok, nil}

  defp parse_version(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.shift_zone!(datetime, "Etc/UTC")}
      _ -> :error
    end
  end

  defp parse_version(_value), do: :error

  defp parse_since(nil), do: 0

  defp parse_since(value) do
    case Integer.parse(value) do
      {since, ""} when since >= 0 -> since
      _ -> 0
    end
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_status(status)
    |> Req.Test.json(body)
  end
end
