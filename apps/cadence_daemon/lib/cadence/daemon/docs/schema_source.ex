defmodule Cadence.Daemon.Docs.SchemaSource do
  @moduledoc """
  Reads the project's `.caddocs.yaml` from the working tree (spec §9.1).

  The file is the source of truth; `Cadence.Shared.Project.docs_schema` is only
  a best-effort local cache. Schema problems are reported, never raised —
  documentation is optional and must never block a commit.
  """

  alias Cadence.Daemon.Repo
  alias Cadence.Shared.Docs.Schema
  alias Cadence.Shared.Project

  @type load_result :: {:ok, Schema.t()} | :no_schema | {:error, atom()}

  @doc """
  Loads and parses the project schema from `work_dir`.

  Returns `{:ok, schema}`, `:no_schema` when the file is absent, or
  `{:error, reason}` with the parser's error atom (or `:unreadable`).
  """
  @spec load(Path.t()) :: load_result()
  def load(work_dir) when is_binary(work_dir) do
    path = Path.join(work_dir, Schema.schema_file())

    case File.read(path) do
      {:ok, yaml} -> Schema.parse(yaml)
      {:error, :enoent} -> :no_schema
      {:error, _reason} -> {:error, :unreadable}
    end
  end

  def load(_work_dir), do: :no_schema

  @doc """
  Loads the schema and updates the project's cached `docs_schema` when it
  changed. Returns the same result as `load/1`; cache writes are best-effort.
  """
  @spec refresh(Ecto.UUID.t(), Path.t()) :: load_result()
  def refresh(project_id, work_dir) do
    case load(work_dir) do
      {:ok, schema} ->
        put_cache(project_id, Schema.to_map(schema))
        {:ok, schema}

      :no_schema ->
        put_cache(project_id, %{})
        :no_schema

      {:error, _reason} = error ->
        error
    end
  end

  defp put_cache(project_id, docs_schema) do
    case Repo.get(Project, project_id) do
      %Project{docs_schema: ^docs_schema} ->
        :ok

      %Project{} = project ->
        case project |> Project.changeset(%{docs_schema: docs_schema}) |> Repo.update() do
          {:ok, _project} -> :ok
          {:error, _changeset} -> :ok
        end

      nil ->
        :ok
    end
  rescue
    _error in [Exqlite.Error, DBConnection.ConnectionError, Ecto.QueryError] -> :ok
  end
end
