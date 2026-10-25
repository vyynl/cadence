defmodule Cadence.Server.ProjectAdmin do
  @moduledoc """
  Owner-level project mutations from the web UI.

  Authorization lives in the LiveView/controller boundary; this context only
  performs the validated database update.
  """

  alias Cadence.Server.{Portfolio, Repo}

  @doc "Set a node's pinned flag, ensuring it belongs to the project."
  @spec set_pinned(Ecto.UUID.t() | String.t(), Ecto.UUID.t() | String.t(), boolean()) ::
          {:ok, Cadence.Shared.Node.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def set_pinned(project_id, node_id, pinned) when is_boolean(pinned) do
    case Portfolio.node_for_project(project_id, node_id) do
      nil ->
        {:error, :not_found}

      node ->
        node
        |> Ecto.Changeset.change(pinned: pinned)
        |> Repo.update()
    end
  end

  def set_pinned(_project_id, _node_id, _pinned), do: {:error, :not_found}
end
