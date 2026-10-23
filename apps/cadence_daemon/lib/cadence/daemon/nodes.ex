defmodule Cadence.Daemon.Nodes do
  @moduledoc """
  Query helpers for a project's nodes.

  These keep the daemon's common list/latest/lookups in one place so the
  commit queue, session resolver, and socket API don't each re-implement the
  same ordering rules (newest first, deterministic by id on ties).
  """

  import Ecto.Query

  alias Cadence.Daemon.Repo
  alias Cadence.Shared.{DAG, Node, UUID}

  @doc "The most recent node in the project, or `nil`."
  @spec latest(Ecto.UUID.t()) :: Node.t() | nil
  def latest(project_id) do
    project_id
    |> recent_query()
    |> limit(1)
    |> Repo.one()
  end

  @doc "All project nodes, newest first."
  @spec list(Ecto.UUID.t()) :: [Node.t()]
  def list(project_id) do
    project_id |> recent_query() |> Repo.all()
  end

  @doc "The most recent node created by `user_id`, or `nil`."
  @spec most_recent_by_user(Ecto.UUID.t(), Ecto.UUID.t() | nil) :: Node.t() | nil
  def most_recent_by_user(_project_id, nil), do: nil

  def most_recent_by_user(project_id, user_id) do
    with {:ok, project_id} <- UUID.cast(project_id),
         {:ok, user_id} <- UUID.cast(user_id) do
      project_id
      |> recent_query()
      |> where([n], n.created_by == ^user_id)
      |> limit(1)
      |> Repo.one()
    else
      :error -> nil
    end
  end

  @doc "The project's preview node (spec §4.4), or `nil`."
  @spec preview(Ecto.UUID.t()) :: Node.t() | nil
  def preview(project_id) do
    case UUID.cast(project_id) do
      {:ok, project_id} -> project_id |> list() |> DAG.preview_node()
      :error -> nil
    end
  end

  defp recent_query(project_id) do
    case UUID.cast(project_id) do
      {:ok, project_id} ->
        Node
        |> where([n], n.project_id == ^project_id)
        |> order_by([n], desc: n.created_at, desc: n.id)

      :error ->
        Node
        |> where([n], false)
        |> order_by([n], desc: n.created_at, desc: n.id)
    end
  end
end
