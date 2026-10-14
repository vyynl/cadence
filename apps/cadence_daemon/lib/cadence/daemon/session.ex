defmodule Cadence.Daemon.Session do
  @moduledoc """
  Per-user, per-project session state: the session pointer and active heads.

  Backed by `Cadence.Shared.Membership` rows keyed `(user_id, project_id)`.
  The session pointer is the node the local user is currently editing from;
  `active_heads` are the nodes this user considers live (see spec §4.3).
  """

  alias Cadence.Daemon.{Env, Repo}
  alias Cadence.Shared.{Membership, Node}

  @role :owner

  @doc """
  Returns the membership for the local user, creating an `owner` membership if
  none exists. Raises on database failure.
  """
  @spec ensure_membership!(Ecto.UUID.t()) :: Membership.t()
  def ensure_membership!(project_id) do
    user_id = Env.local_user_id()

    case Repo.get_by(Membership, user_id: user_id, project_id: project_id) do
      nil ->
        %Membership{}
        |> Membership.changeset(%{
          user_id: user_id,
          project_id: project_id,
          role: @role,
          active_heads: []
        })
        |> Repo.insert!()

      membership ->
        membership
    end
  end

  @doc "Returns the current node (session pointer) for the local user, or `nil`."
  @spec current_node(Ecto.UUID.t()) :: Node.t() | nil
  def current_node(project_id) do
    case Repo.get_by(Membership, user_id: Env.local_user_id(), project_id: project_id) do
      %{session_pointer: nil} -> nil
      %{session_pointer: node_id} -> Repo.get(Node, node_id)
      nil -> nil
    end
  end

  @doc """
  Moves the local user's session pointer to `node_id`.

  Returns `{:ok, membership}` on success, or `{:error, :not_found}` when the
  node (or membership) does not exist or does not belong to `project_id`.
  """
  @spec switch(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Membership.t()} | {:error, :not_found}
  def switch(project_id, node_id) do
    with membership when not is_nil(membership) <-
           Repo.get_by(Membership, user_id: Env.local_user_id(), project_id: project_id),
         node when not is_nil(node) <- Repo.get(Node, node_id),
         true <- node.project_id == project_id do
      {:ok, membership} =
        membership
        |> Membership.changeset(%{session_pointer: node_id})
        |> Repo.update()

      {:ok, membership}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Advances the session pointer to `new_node` and adds `parent_node` to the
  active-heads set (spec §6.4 spawn semantics). Returns `{:ok, membership}`.
  """
  @spec spawn_after(Ecto.UUID.t(), Node.t(), Node.t()) :: {:ok, Membership.t()}
  def spawn_after(project_id, parent_node, new_node) do
    membership = ensure_membership!(project_id)

    active_heads =
      membership.active_heads
      |> then(&((parent_node.id in &1 && &1) || [parent_node.id | &1]))

    {:ok, membership} =
      membership
      |> Membership.changeset(%{session_pointer: new_node.id, active_heads: active_heads})
      |> Repo.update()

    {:ok, membership}
  end

  @doc """
  Advances the session pointer to `new_node` after a normal commit, dropping
  the superseded parent(s) from `active_heads` (spec §3.2, §5.3).
  """
  @spec commit_after(Ecto.UUID.t(), Node.t()) :: {:ok, Membership.t()}
  def commit_after(project_id, new_node) do
    membership = ensure_membership!(project_id)
    active_heads = (membership.active_heads || []) -- new_node.parents

    {:ok, membership} =
      membership
      |> Membership.changeset(%{session_pointer: new_node.id, active_heads: active_heads})
      |> Repo.update()

    {:ok, membership}
  end
end
