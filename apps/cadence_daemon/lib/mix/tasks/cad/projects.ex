defmodule Mix.Tasks.Cad.Projects do
  use Mix.Task

  alias Cadence.Daemon.Client

  @shortdoc "List registered Cadence projects"

  @impl Mix.Task
  def run(_args) do
    %{body: %{"projects" => projects}} = Client.request("GET", "/projects")

    Enum.each(projects, fn p ->
      Mix.shell().info("#{p["slug"]}\t#{p["name"]}\t#{p["work_dir"]}")
    end)
  end
end
