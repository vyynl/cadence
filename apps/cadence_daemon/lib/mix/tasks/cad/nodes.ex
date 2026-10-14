defmodule Mix.Tasks.Cad.Nodes do
  use Mix.Task

  alias Cadence.Daemon.Client

  @shortdoc "List nodes for a project: mix cad.nodes SLUG_OR_ID"

  @impl Mix.Task
  def run([slug_or_id]) do
    project_id = Client.resolve_project_id(slug_or_id)
    %{"nodes" => nodes} = Client.expect!("GET", "/nodes?project_id=#{project_id}")

    Enum.each(nodes, fn n ->
      flags = Enum.join(n["flags"], ",")
      Mix.shell().info("#{String.slice(n["id"], 0, 8)}  #{flags}  #{n["message"]}")
    end)
  end

  def run(_), do: Mix.raise("usage: mix cad.nodes SLUG_OR_ID")
end
