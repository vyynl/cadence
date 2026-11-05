defmodule Cadence.Server.Authorization do
  @moduledoc """
  Shared server-side project role checks.

  Contexts enforce authorization at their own boundary. This module only
  resolves the membership row and answers role questions; it never performs
  mutations.
  """

  alias Cadence.Server.Repo
  alias Cadence.Shared.{Membership, UUID}

  @view_roles [:owner, :trusted, :viewer]
  @propose_roles [:owner, :trusted]

  @doc "Fetch a user's membership in a project, or `nil` for invalid input."
  @spec membership(Ecto.UUID.t() | String.t(), Ecto.UUID.t() | String.t()) ::
          Membership.t() | nil
  def membership(user_id, project_id) do
    with {:ok, user_id} <- UUID.cast(user_id),
         {:ok, project_id} <- UUID.cast(project_id) do
      Repo.get_by(Membership, user_id: user_id, project_id: project_id)
    else
      :error -> nil
    end
  end

  @doc "Whether the membership may read project proposals."
  @spec can_view?(Membership.t() | nil) :: boolean()
  def can_view?(nil), do: false
  def can_view?(%Membership{role: role}), do: role in @view_roles

  @doc "Whether the membership may create a meld or promotion proposal."
  @spec can_propose?(Membership.t() | nil) :: boolean()
  def can_propose?(nil), do: false
  def can_propose?(%Membership{role: role}), do: role in @propose_roles

  @doc """
  Whether the membership may decide proposals or resolve blocking incidents.

  Owners always may; trusted members only with the per-project `approver`
  grant.
  """
  @spec can_decide?(Membership.t() | nil) :: boolean()
  def can_decide?(nil), do: false
  def can_decide?(%Membership{role: :owner}), do: true
  def can_decide?(%Membership{role: :trusted, approver: true}), do: true
  def can_decide?(%Membership{}), do: false
end
