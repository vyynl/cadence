defmodule Mix.Tasks.Cad.Switch do
  use Mix.Task

  alias Cadence.Daemon.Client

  @shortdoc "Move the session pointer: mix cad.switch SLUG_OR_ID NODE_ID"

  @impl Mix.Task
  def run([slug_or_id, node_id]) do
    project_id = Client.resolve_project_id(slug_or_id)

    %{"session_pointer" => pointer} =
      Client.expect!("POST", "/switch", %{"project_id" => project_id, "node_id" => node_id})

    Mix.shell().info("session pointer -> #{String.slice(pointer, 0, 8)}")
  end

  def run(_), do: Mix.raise("usage: mix cad.switch SLUG_OR_ID NODE_ID")
end
