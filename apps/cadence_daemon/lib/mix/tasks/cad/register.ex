defmodule Mix.Tasks.Cad.Register do
  use Mix.Task

  alias Cadence.Daemon.Client

  @shortdoc "Register a project: mix cad.register NAME SLUG WORK_DIR"

  @impl Mix.Task
  def run([name, slug, work_dir]) do
    case Client.request("POST", "/projects", %{
           "name" => name,
           "slug" => slug,
           "work_dir" => work_dir
         }) do
      %{status: status, body: body} when status in 200..299 ->
        Mix.shell().info("registered #{body["project"]["slug"]}")

      %{status: _, body: %{"error" => error}} ->
        Mix.raise(error)
    end
  end

  def run(_), do: Mix.raise("usage: mix cad.register NAME SLUG WORK_DIR")
end
