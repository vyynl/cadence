defmodule Cadence.Server.Portfolio do
  @moduledoc """
  Read-only queries for the public project pages.

  Public pages only expose the preview node (spec §7.1). The full DAG and
  non-preview nodes are reserved for authenticated members and will use the
  same context in later slices.
  """

  import Ecto.Query

  alias Cadence.Server.Repo
  alias Cadence.Shared.{Membership, Node, Project, UUID}

  @doc "Fetch a project by its URL slug."
  @spec get_project_by_slug(String.t()) :: {:ok, Project.t()} | {:error, :not_found}
  def get_project_by_slug(slug) when is_binary(slug) do
    case Repo.get_by(Project, slug: slug) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  def get_project_by_slug(_slug), do: {:error, :not_found}

  @doc """
  List a project's nodes, newest first with a deterministic tie-break.

  Intended for authenticated full-DAG views; public pages must use
  `preview_node/1` instead.
  """
  @spec list_nodes(Ecto.UUID.t() | String.t()) :: [Node.t()]
  def list_nodes(project_id) do
    with {:ok, project_id} <- UUID.cast(project_id) do
      Repo.all(ordered_nodes(project_id))
    else
      :error -> []
    end
  end

  @doc """
  Resolve the preview node (spec §4.4): pinned, then functioning, then newest.
  """
  @spec preview_node(Ecto.UUID.t() | String.t()) :: Node.t() | nil
  def preview_node(project_id) do
    with {:ok, project_id} <- UUID.cast(project_id) do
      ordered = ordered_nodes(project_id)

      Repo.one(from(n in ordered, where: n.pinned == true, limit: 1)) ||
        Repo.one(
          from(n in ordered,
            where: fragment("? = ANY(?)", "functioning", n.flags),
            limit: 1
          )
        ) ||
        Repo.one(from(n in ordered, limit: 1))
    else
      :error -> nil
    end
  end

  @doc "Fetch a user's membership in a project, or `nil`."
  @spec membership_for(Ecto.UUID.t() | String.t(), Ecto.UUID.t() | String.t()) ::
          Membership.t() | nil
  def membership_for(user_id, project_id) do
    with {:ok, user_id} <- UUID.cast(user_id),
         {:ok, project_id} <- UUID.cast(project_id) do
      Repo.get_by(Membership, user_id: user_id, project_id: project_id)
    else
      :error -> nil
    end
  end

  defp ordered_nodes(project_id) do
    from(n in Node,
      where: n.project_id == ^project_id,
      order_by: [desc: n.created_at, desc: n.id]
    )
  end
end
