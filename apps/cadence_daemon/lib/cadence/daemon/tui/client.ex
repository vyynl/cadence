defmodule Cadence.Daemon.TUI.Client do
  @moduledoc """
  Typed wrapper over `Cadence.Daemon.Client` for the TUI.

  The TUI is a pure socket client (plan D2): every read and mutation goes
  through the daemon's Unix socket, exactly like the Neovim plugin. This module
  is the only place that knows the endpoint paths and the response shapes, and
  it normalises every failure into one shape so the scene can render a single
  status line:

      {:ok, decoded_body}
      {:error, %{status: 400..599 | :unreachable | :invalid_response, message: String.t()}}

  The module is injected through the `:tui_client` application env and replaced
  by a fake in tests (the same pattern as `:meld_llm` / `:actions_docker`).

  Every function takes `:socket_path` in its trailing options and defaults to
  `Cadence.Daemon.API.socket_path/0`.
  """

  alias Cadence.Daemon.Client, as: Socket

  @read_timeout 5_000
  @mutation_timeout 30_000

  @type error :: %{
          status: 400..599 | :unreachable | :invalid_response,
          message: String.t()
        }
  @type result :: {:ok, map() | nil} | {:error, error()}

  @doc "`GET /health`."
  @spec health(keyword()) :: result()
  def health(opts \\ []), do: get("/health", opts)

  @doc "`GET /projects`."
  @spec projects(keyword()) :: result()
  def projects(opts \\ []), do: get("/projects", opts)

  @doc "`GET /graph` for one project."
  @spec graph(String.t(), keyword()) :: result()
  def graph(project_id, opts \\ []) do
    get("/graph?" <> query(project_id: project_id), opts)
  end

  @doc "`GET /diff` for one node."
  @spec diff(String.t(), String.t(), keyword()) :: result()
  def diff(project_id, node_id, opts \\ []) do
    get("/diff?" <> query(project_id: project_id, node_id: node_id), opts)
  end

  @doc "`POST /switch` to move the session pointer to `node_id`."
  @spec switch(String.t(), String.t(), keyword()) :: result()
  def switch(project_id, node_id, opts \\ []) do
    post("/switch", %{project_id: project_id, node_id: node_id}, mutation_opts(opts))
  end

  @doc "`POST /spawn` to branch from the current node."
  @spec spawn(String.t(), String.t(), keyword()) :: result()
  def spawn(project_id, name, opts \\ []) do
    post("/spawn", %{project_id: project_id, name: name}, mutation_opts(opts))
  end

  @doc "`POST /union` for two to eight parent nodes."
  @spec union(String.t(), [String.t()], keyword()) :: result()
  def union(project_id, parent_node_ids, opts \\ []) do
    post(
      "/union",
      %{project_id: project_id, parent_node_ids: parent_node_ids},
      Keyword.put_new(opts, :timeout, Cadence.Daemon.Env.sync_union_timeout_ms() + @read_timeout)
    )
  end

  @doc "`GET /proposals` for one project."
  @spec proposals(String.t(), keyword()) :: result()
  def proposals(project_id, opts \\ []) do
    get("/proposals?" <> query(project_id: project_id), opts)
  end

  @doc """
  `POST /docs/sync`.

  Omitting `node_id` asks the daemon to use its session anchor.
  """
  @spec docs_sync(String.t(), String.t() | nil, keyword()) :: result()
  def docs_sync(project_id, node_id, opts \\ []) do
    post("/docs/sync", drop_nil(%{project_id: project_id, node_id: node_id}), mutation_opts(opts))
  end

  @doc """
  `GET /docs/diff`.

  Omitting `node_id` asks the daemon to use its session anchor.
  """
  @spec docs_diff(String.t(), String.t() | nil, keyword()) :: result()
  def docs_diff(project_id, node_id, opts \\ []) do
    get("/docs/diff?" <> query(drop_nil(project_id: project_id, node_id: node_id)), opts)
  end

  # -- request plumbing ------------------------------------------------------

  defp get(path, opts) do
    request("GET", path, nil, opts)
  end

  defp post(path, body, opts) do
    request("POST", path, body, opts)
  end

  defp mutation_opts(opts), do: Keyword.put_new(opts, :timeout, @mutation_timeout)

  defp request(method, path, body, opts) do
    socket = Keyword.get(opts, :socket_path, Cadence.Daemon.API.socket_path())
    timeout = Keyword.get(opts, :timeout, @read_timeout)

    try do
      case Socket.request(method, path, body, socket, timeout) do
        %{status: status, body: decoded} when status in 200..299 ->
          {:ok, decoded}

        %{status: status, body: decoded} ->
          {:error, %{status: status, message: message(decoded)}}
      end
    rescue
      # The socket client matches on connect success and decodes with `!`, so a
      # down daemon or a truncated reply surfaces here. Map both to one shape
      # instead of crashing the renderer.
      e in MatchError ->
        {:error,
         %{
           status: :unreachable,
           message: "daemon unreachable at #{socket}: #{Exception.message(e)}"
         }}

      e in [ArgumentError, CaseClauseError, Jason.DecodeError] ->
        {:error,
         %{status: :invalid_response, message: "invalid daemon response: #{Exception.message(e)}"}}

      e in RuntimeError ->
        {:error, %{status: :unreachable, message: Exception.message(e)}}
    end
  end

  defp message(%{"error" => message}) when is_binary(message), do: message
  defp message(%{"error" => _other}), do: "request failed"
  defp message(nil), do: "empty response"
  defp message(_other), do: "request failed"

  defp query(fields) do
    fields
    |> drop_nil()
    |> Enum.map_join("&", fn {key, value} ->
      "#{key}=#{URI.encode_www_form(to_string(value))}"
    end)
  end

  defp drop_nil(%{} = map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp drop_nil(fields) when is_list(fields) do
    Enum.reject(fields, fn {_key, value} -> is_nil(value) end)
  end
end
