defmodule Mix.Tasks.Cad.Spawn do
  use Mix.Task

  alias Cadence.Daemon.Client

  @shortdoc "Spawn a sandbox child from the current node: mix cad.spawn SLUG_OR_ID [NAME]"

  @impl Mix.Task
  def run([slug_or_id | rest]) do
    project_id = Client.resolve_project_id(slug_or_id)
    name = List.first(rest)

    body = %{"project_id" => project_id} |> maybe_put("name", name)

    case Client.request("POST", "/spawn", body) do
      %{status: status, body: %{"node" => node}} when status in 200..299 ->
        Mix.shell().info("spawned #{String.slice(node["id"], 0, 8)}")

      %{status: _, body: %{"error" => error}} ->
        Mix.raise(error)
    end
  end

  def run(_), do: Mix.raise("usage: mix cad.spawn SLUG_OR_ID [NAME]")

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
