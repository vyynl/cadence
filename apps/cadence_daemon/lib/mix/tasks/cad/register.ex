defmodule Mix.Tasks.Cad.Register do
  use Mix.Task

  alias Cadence.Daemon.Client

  @shortdoc "Register a project: mix cad.register NAME SLUG WORK_DIR"

  @impl Mix.Task
  def run([name, slug, work_dir]) do
    %{"project" => project} =
      Client.expect!("POST", "/projects", %{
        "name" => name,
        "slug" => slug,
        "work_dir" => work_dir
      })

    Mix.shell().info("registered #{project["slug"]}")
  end

  def run(_), do: Mix.raise("usage: mix cad.register NAME SLUG WORK_DIR")
end
