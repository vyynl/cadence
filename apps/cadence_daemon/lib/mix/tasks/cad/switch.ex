defmodule Mix.Tasks.Cad.Switch do
  use Mix.Task

  alias Cadence.Daemon.Client

  @shortdoc "Move the session pointer: mix cad.switch SLUG_OR_ID NODE_ID"

  @impl Mix.Task
  def run([slug_or_id, node_id]) do
    project_id = Client.resolve_project_id(slug_or_id)

    case Client.request("POST", "/switch", %{"project_id" => project_id, "node_id" => node_id}) do
      %{status: status, body: %{"session_pointer" => pointer}} when status in 200..299 ->
        Mix.shell().info("session pointer -> #{String.slice(pointer, 0, 8)}")

      %{status: _, body: %{"error" => error}} ->
        Mix.raise(error)
    end
  end

  def run(_), do: Mix.raise("usage: mix cad.switch SLUG_OR_ID NODE_ID")
end
