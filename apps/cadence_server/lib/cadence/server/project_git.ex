defmodule Cadence.Server.ProjectGit do
  @moduledoc """
  Resolves the per-project bare Git object store on the server.

  Each project's objects live under `CAD_GIT_STORE_PATH/<project_id>`.
  """

  alias Cadence.Shared.GitStore

  @doc "Absolute path to a project's bare object store."
  @spec path(String.t()) :: Path.t()
  def path(project_id) when is_binary(project_id) do
    project_id =
      case Ecto.UUID.cast(project_id) do
        {:ok, id} -> id
        :error -> raise ArgumentError, "invalid project id: #{inspect(project_id)}"
      end

    Path.join(git_store_path(), project_id)
  end

  @doc "Open a project's store for reading without creating anything."
  @spec open(String.t()) :: GitStore.t()
  def open(project_id), do: GitStore.open(path(project_id), bare: true)

  @doc "Ensure a project's store exists and return a handle for writing."
  @spec init(String.t()) :: GitStore.t()
  def init(project_id) do
    path = path(project_id)
    File.mkdir_p!(path)
    GitStore.init(path, bare: true)
  end

  defp git_store_path do
    Application.fetch_env!(:cadence_server, :git_store_path)
  end
end
