defmodule Cadence.Server.Proposals do
  @moduledoc """
  Proposal lifecycle for pending melds and promotions (spec §6.6).

  Proposals are server-only. Creating one is non-disruptive: no node is created
  and no session pointer moves. Approval is a state transition only in this
  slice; attaching/creating the meld node and broadcasting belong to the later
  review slice. A critical open incident blocks approval.
  """

  import Ecto.Query

  alias Cadence.Server.{Authorization, Incidents, Proposal, Repo}
  alias Cadence.Shared.{Node, Project, UUID}

  @create_fields [
    :project_id,
    :kind,
    :parent_ids,
    :target_node_id,
    :result_tree_sha,
    :meld_commit_sha
  ]

  @doc """
  Creates a pending proposal for `actor`.

  Owners and trusted members may propose. Meld parents and promotion targets
  must belong to the same project.
  """
  @spec create(map(), map()) ::
          {:ok, Proposal.t()} | {:error, Ecto.Changeset.t() | term()}
  def create(actor, attrs) when is_map(attrs) do
    attrs = attrs |> Map.take(@create_fields) |> Map.put(:proposer_id, actor.id)
    changeset = Proposal.changeset(attrs)

    if changeset.valid? do
      project_id = Ecto.Changeset.get_field(changeset, :project_id)

      with {:ok, project_id} <- uuid(project_id),
           {:ok, _project} <- fetch_project(project_id),
           {:ok, _membership} <- authorize_proposer(actor, project_id),
           :ok <- validate_references(changeset, project_id) do
        Repo.insert(changeset)
      end
    else
      {:error, changeset}
    end
  end

  @doc "Lists a project's proposals newest first for any project member."
  @spec list(map(), Ecto.UUID.t() | String.t()) ::
          {:ok, [Proposal.t()]} | {:error, :not_found | :forbidden}
  def list(actor, project_id) do
    with {:ok, project_id} <- uuid(project_id),
         {:ok, _project} <- fetch_project(project_id),
         {:ok, _membership} <- authorize_viewer(actor, project_id) do
      {:ok,
       Repo.all(
         from(p in Proposal,
           where: p.project_id == ^project_id,
           order_by: [desc: p.created_at, desc: p.id]
         )
       )}
    end
  end

  @doc """
  Fetches a proposal by its stable public token.

  Proposal links are public read-only; mutation actions re-check membership and
  roles separately.
  """
  @spec get_by_token(String.t()) :: {:ok, Proposal.t()} | {:error, :not_found}
  def get_by_token(token) when is_binary(token) do
    case Repo.get_by(Proposal, token: token) do
      nil -> {:error, :not_found}
      proposal -> {:ok, proposal}
    end
  end

  def get_by_token(_token), do: {:error, :not_found}

  @doc "Approves a pending proposal. Idempotent for an already-approved one."
  @spec approve(map(), Ecto.UUID.t() | String.t(), Ecto.UUID.t() | String.t()) ::
          {:ok, Proposal.t()} | {:error, term()}
  def approve(actor, project_id, proposal_id) do
    decide(actor, project_id, proposal_id, :approved)
  end

  @doc "Rejects a pending proposal. Idempotent for an already-rejected one."
  @spec reject(map(), Ecto.UUID.t() | String.t(), Ecto.UUID.t() | String.t()) ::
          {:ok, Proposal.t()} | {:error, term()}
  def reject(actor, project_id, proposal_id) do
    decide(actor, project_id, proposal_id, :rejected)
  end

  defp decide(actor, project_id, proposal_id, decision) do
    with {:ok, project_id} <- uuid(project_id),
         {:ok, proposal_id} <- uuid(proposal_id),
         {:ok, _membership} <- authorize_decider(actor, project_id) do
      Repo.transaction(fn ->
        proposal =
          Repo.one(
            from(p in Proposal,
              where: p.id == ^proposal_id and p.project_id == ^project_id,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        cond do
          proposal.status == decision ->
            proposal

          proposal.status != :pending ->
            Repo.rollback(:invalid_transition)

          decision == :approved and Incidents.blocking_proposal?(proposal.id) ->
            Repo.rollback(:blocked)

          true ->
            proposal
            |> Ecto.Changeset.change(
              status: decision,
              reviewer_id: actor.id,
              decided_at: DateTime.utc_now()
            )
            |> Repo.update()
            |> case do
              {:ok, proposal} -> proposal
              {:error, changeset} -> Repo.rollback(changeset)
            end
        end
      end)
    end
  end

  defp validate_references(changeset, project_id) do
    case Ecto.Changeset.get_field(changeset, :kind) do
      :meld -> validate_parent_nodes(changeset, project_id)
      :promotion -> validate_target_node(changeset, project_id)
      _kind -> :ok
    end
  end

  defp validate_parent_nodes(changeset, project_id) do
    parent_ids = Ecto.Changeset.get_field(changeset, :parent_ids) || []
    unique_parent_ids = Enum.uniq(parent_ids)

    count =
      Repo.aggregate(
        from(n in Node, where: n.project_id == ^project_id and n.id in ^unique_parent_ids),
        :count
      )

    if count == length(unique_parent_ids), do: :ok, else: {:error, :invalid_parent}
  end

  defp validate_target_node(changeset, project_id) do
    target_id = Ecto.Changeset.get_field(changeset, :target_node_id)

    case Repo.get_by(Node, id: target_id, project_id: project_id) do
      nil -> {:error, :invalid_target}
      _node -> :ok
    end
  end

  defp authorize_proposer(actor, project_id) do
    case Authorization.membership(actor.id, project_id) do
      nil ->
        {:error, :forbidden}

      membership ->
        if Authorization.can_propose?(membership),
          do: {:ok, membership},
          else: {:error, :forbidden}
    end
  end

  defp authorize_viewer(actor, project_id) do
    case Authorization.membership(actor.id, project_id) do
      nil ->
        {:error, :forbidden}

      membership ->
        if Authorization.can_view?(membership), do: {:ok, membership}, else: {:error, :forbidden}
    end
  end

  defp authorize_decider(actor, project_id) do
    case Authorization.membership(actor.id, project_id) do
      nil ->
        {:error, :forbidden}

      membership ->
        if Authorization.can_decide?(membership),
          do: {:ok, membership},
          else: {:error, :forbidden}
    end
  end

  defp fetch_project(project_id) do
    case Repo.get(Project, project_id) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  defp uuid(value) do
    case UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end
end
