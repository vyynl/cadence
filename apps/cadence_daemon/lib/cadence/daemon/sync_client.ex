defmodule Cadence.Daemon.SyncClient do
  @moduledoc """
  Thin `Req` client for the cloud sync protocol (spec §10).

  Every function returns tagged tuples and performs exactly one HTTP request;
  retry/backoff policy belongs to the caller (`Cadence.Daemon.Sync`). The client
  reads `CAD_SERVER_URL`/`CAD_AUTH_TOKEN` through `Cadence.Daemon.Env` and is
  injectable with `Req.Test` via `Env.sync_req_options/0`.
  """

  alias Cadence.Daemon.Env
  alias Cadence.Shared.Project
  alias Cadence.Shared.Sync.{ObjectsExists, PushPreferences}

  @doc "Whether a server URL and bearer token are configured."
  @spec configured?() :: boolean()
  def configured? do
    present?(Env.server_url()) and present?(Env.auth_token())
  end

  @doc "Returns the authenticated server user ID."
  @spec me() :: {:ok, Ecto.UUID.t()} | {:error, term()}
  def me do
    with {:ok, body} <- request(:get, "/sync/me") do
      case body do
        %{"user_id" => user_id} when is_binary(user_id) -> {:ok, user_id}
        _ -> {:error, {:invalid_response, body}}
      end
    end
  end

  @doc """
  Pushes a batch of encoded nodes.

  `nodes` are the wire maps produced by `Cadence.Shared.Sync.NodeCodec`.
  Returns `%{mappings: [%{"local_id" => ..., "cloud_id" => ...}]}`.
  """
  @spec push([map()] | %{nodes: [map()]}) ::
          {:ok, %{mappings: [map()]}} | {:error, term()}
  def push(%{nodes: nodes}), do: push(nodes)

  def push(nodes) when is_list(nodes) do
    with {:ok, body} <- request(:post, "/sync/nodes", json: %{nodes: nodes}) do
      case body do
        %{"mappings" => mappings} when is_list(mappings) ->
          {:ok, %{mappings: mappings}}

        _ ->
          {:error, {:invalid_response, body}}
      end
    end
  end

  @doc """
  Asks the server which object SHAs it already holds (spec §10.2, §10.6).

  Returns the present subset in server order. A failure is not fatal: the caller
  falls back to sending every object.
  """
  @spec objects_exist(Ecto.UUID.t(), [String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  def objects_exist(project_id, shas) when is_list(shas) do
    payload = %ObjectsExists{project_id: project_id, shas: shas}

    with {:ok, body} <- request(:post, "/sync/objects/exists", json: payload) do
      case body do
        %{"present" => present} when is_list(present) ->
          if Enum.all?(present, &is_binary/1) do
            {:ok, present}
          else
            {:error, {:invalid_response, body}}
          end

        _ ->
          {:error, {:invalid_response, body}}
      end
    end
  end

  @doc """
  Pulls nodes for `project_id` after `cursor` (`nil` starts from the beginning).

  Returns `%{nodes: [...], cursor: next_cursor, preferences: ...}`.
  """
  @spec pull(Ecto.UUID.t(), String.t() | nil) ::
          {:ok, %{nodes: [map()], cursor: String.t(), preferences: map() | nil}}
          | {:error, term()}
  def pull(project_id, cursor \\ nil) do
    params =
      [project_id: project_id]
      |> maybe_put(:since, cursor)

    with {:ok, body} <- request(:get, "/sync/nodes", params: params) do
      case body do
        %{"nodes" => nodes, "cursor" => next_cursor}
        when is_list(nodes) and is_binary(next_cursor) ->
          {:ok,
           %{
             nodes: nodes,
             cursor: next_cursor,
             preferences: Map.get(body, "preferences")
           }}

        _ ->
          {:error, {:invalid_response, body}}
      end
    end
  end

  @doc """
  Pushes the caller's versioned preferences to the server.

  Accepts a `Cadence.Shared.Sync.PushPreferences` struct or a map with the same
  keys. Returns the server's current preferences, which may be newer than the
  version that was pushed.
  """
  @spec push_preferences(PushPreferences.t() | map()) ::
          {:ok, %{preferences: map()}} | {:error, term()}
  def push_preferences(%PushPreferences{} = preferences) do
    push_preferences(Map.from_struct(preferences))
  end

  def push_preferences(preferences) when is_map(preferences) do
    with {:ok, body} <- request(:post, "/sync/preferences", json: preferences) do
      case body do
        %{"preferences" => %{} = current} -> {:ok, %{preferences: current}}
        _ -> {:error, {:invalid_response, body}}
      end
    end
  end

  @doc """
  Provisions the local project on the server.

  The server uses the same project ID and makes the authenticated user the
  owner. Repeat calls are idempotent.
  """
  @spec provision(Project.t()) :: {:ok, map()} | {:error, term()}
  def provision(%Project{} = project) do
    payload = %{
      project: %{
        id: project.id,
        name: project.name,
        slug: project.slug
      }
    }

    with {:ok, body} <- request(:post, "/sync/projects", json: payload) do
      case body do
        %{"project" => project} when is_map(project) -> {:ok, project}
        _ -> {:error, {:invalid_response, body}}
      end
    end
  end

  @doc """
  Requests a meld proposal (`POST /sync/union`).

  Synchronous: the server may call the meld model, so this uses
  `Env.sync_union_timeout_ms/0` unless a `:receive_timeout` is passed. Returns
  the proposal reference; no node exists until approval.
  """
  @spec union(Ecto.UUID.t(), [Ecto.UUID.t()], keyword()) ::
          {:ok,
           %{proposal_id: String.t(), proposal_token: String.t(), status: term(), kind: term()}}
          | {:error, term()}
  def union(project_id, parent_node_ids, opts \\ []) when is_list(parent_node_ids) do
    payload = %{project_id: project_id, parent_node_ids: parent_node_ids}
    opts = Keyword.put_new(opts, :receive_timeout, Env.sync_union_timeout_ms())

    with {:ok, body} <- request(:post, "/sync/union", Keyword.merge([json: payload], opts)) do
      case body do
        %{"proposal_id" => proposal_id, "proposal_token" => proposal_token}
        when is_binary(proposal_id) and is_binary(proposal_token) ->
          {:ok,
           %{
             proposal_id: proposal_id,
             proposal_token: proposal_token,
             status: Map.get(body, "status"),
             kind: Map.get(body, "kind")
           }}

        _other ->
          {:error, {:invalid_response, body}}
      end
    end
  end

  defp request(method, path, opts \\ []) do
    with {:ok, server_url} <- required_config(Env.server_url()),
         {:ok, token} <- required_config(Env.auth_token()) do
      request_opts =
        [
          method: method,
          url: path,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"accept", "application/json"}
          ],
          receive_timeout: Env.sync_request_timeout_ms(),
          retry: false
        ]
        |> Keyword.merge(opts)
        |> Keyword.merge(Env.sync_req_options())

      req = Req.new(base_url: String.trim_trailing(server_url, "/"))

      case Req.request(req, request_opts) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          {:ok, body}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:http, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp required_config(value) when is_binary(value) and value != "", do: {:ok, value}
  defp required_config(_value), do: {:error, :not_configured}

  defp present?(value), do: is_binary(value) and value != ""

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Keyword.put(params, key, value)
end
