defmodule Cadence.Server.Proposals do
  @moduledoc """
  Proposal lifecycle for pending melds and promotions (spec §6.6).

  Proposals are server-only. Creating one is non-disruptive: no node is created
  and no session pointer moves.

  Approval is a decision plus materialization, in one `FOR UPDATE`
  transaction:

  - the stored result is verified against the object store
    (`result_integrity/2`) before any state changes;
  - a meld approval attaches the node that carries `meld_commit_sha` (or
    inserts it) with `pinned: true` and `in-progress` — never `functioning`
    (§3.1);
  - a promotion approval only pins the target node.

  A critical open incident blocks approval. A failed integrity check rolls the
  decision back and opens a critical `scan_incomplete` proposal incident, so an
  unverifiable result cannot be approved until that incident is resolved.

  Successful decisions broadcast `{:proposal_decided, project_id, proposal_id,
  status}`; a fresh meld approval also broadcasts `{:nodes_pushed, project_id,
  [node_id]}` for the node ids a consumer should refresh (a new node or a
  previously existing one that was just pinned). An idempotent re-decision
  repeats `proposal_decided` with the stored status. Nothing is broadcast when
  a decision is refused.
  """

  import Ecto.Query

  alias Cadence.Server.{Authorization, Incidents, Portfolio, ProjectGit, Proposal, Repo}
  alias Cadence.Shared.{GitStore, Meld, Node, Project, UUID}

  @docs_state :pending

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

  @doc """
  Fetches one proposal of `project_id` for any project member.

  Mirrors `list/2`: an unknown project is `:not_found`, a non-member or a
  member of a different project is `:forbidden`.
  """
  @spec get(map(), Ecto.UUID.t() | String.t(), Ecto.UUID.t() | String.t()) ::
          {:ok, Proposal.t()} | {:error, :not_found | :forbidden}
  def get(actor, project_id, proposal_id) do
    with {:ok, project_id} <- uuid(project_id),
         {:ok, proposal_id} <- uuid(proposal_id),
         {:ok, _project} <- fetch_project(project_id),
         {:ok, _membership} <- authorize_viewer(actor, project_id) do
      case Repo.get_by(Proposal, id: proposal_id, project_id: project_id) do
        nil -> {:error, :not_found}
        proposal -> {:ok, proposal}
      end
    end
  end

  @doc """
  Verifies that a meld proposal's stored result is still approvable.

  Approval acts on `result_tree_sha`, while the reviewer saw the diff built
  from `meld_commit_sha`; this check closes that gap. The commit must exist,
  be a commit, and every object reachable from it must be present, and its
  tree must equal the proposal's `result_tree_sha`.

  `project_id` must be the project that owns the proposal: it selects the
  object store. Call it with a proposal obtained from `get/3` or
  `get_by_token/1`; passing a client-controlled `project_id` would make it an
  object-store probe. Promotions carry no result and are always `:ok`. Never
  raises, even on a corrupt object store.
  """
  @spec result_integrity(Ecto.UUID.t() | String.t(), Proposal.t()) ::
          :ok | {:error, :missing_objects | :tree_mismatch | :not_a_commit}
  def result_integrity(_project_id, %Proposal{kind: :promotion}), do: :ok

  def result_integrity(project_id, %Proposal{kind: :meld} = proposal) do
    with {:ok, commit_sha} <- cast_sha(proposal.meld_commit_sha) do
      verify_result(project_id, commit_sha, proposal.result_tree_sha)
    end
  end

  def result_integrity(_project_id, _proposal), do: {:error, :missing_objects}

  # The store holds untrusted bytes: a structurally corrupt but decompressible
  # object can raise inside the decoder. Integrity is a fence, so anything
  # unexpected fails closed as "objects missing" instead of escaping.
  defp verify_result(project_id, commit_sha, result_tree_sha) do
    repo = ProjectGit.open(project_id)

    case GitStore.objects_from(repo, commit_sha) do
      {:ok, _objects} -> check_result_tree(repo, commit_sha, result_tree_sha)
      {:error, :not_a_commit} -> {:error, :not_a_commit}
      {:error, _reason} -> {:error, :missing_objects}
    end
  rescue
    _error -> {:error, :missing_objects}
  catch
    _kind, _value -> {:error, :missing_objects}
  end

  @doc """
  The node a decided proposal produced, or `nil`.

  A meld's node is the one carrying `meld_commit_sha` in the same project (no
  extra column, see D7); a promotion's node is its target. Pending and
  rejected proposals have no result node.
  """
  @spec result_node(Proposal.t()) :: Node.t() | nil
  def result_node(%Proposal{status: :approved, kind: :meld} = proposal) do
    case cast_sha(proposal.meld_commit_sha) do
      {:ok, commit_sha} ->
        Repo.one(
          from(n in Node,
            where: n.project_id == ^proposal.project_id and n.git_commit_sha == ^commit_sha,
            order_by: [asc: n.created_at, asc: n.id],
            limit: 1
          )
        )

      {:error, _reason} ->
        nil
    end
  end

  def result_node(%Proposal{status: :approved, kind: :promotion} = proposal) do
    Portfolio.node_for_project(proposal.project_id, proposal.target_node_id)
  end

  def result_node(%Proposal{}), do: nil

  @doc """
  Approves a pending proposal. Idempotent for an already-approved one.

  Must run outside a caller-owned transaction: the integrity failure path
  rolls back and then opens an incident, so wrapping it in an outer
  `Repo.transaction/1` would discard that caller work.
  """
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
         {:ok, _project} <- fetch_project(project_id),
         {:ok, _membership} <- authorize_decider(actor, project_id) do
      case Repo.transaction(fn -> transition(actor, project_id, proposal_id, decision) end) do
        {:ok, {proposal, node_id}} ->
          broadcast_decision(proposal, node_id)
          {:ok, proposal}

        {:error, {:integrity_failed, reason}} ->
          open_integrity_incident(project_id, proposal_id, reason)
          {:error, :integrity_failed}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Returns `{proposal, attached_node_id | nil}`. Only a fresh meld approval
  # attaches a node; idempotent re-decisions and rejections attach nothing.
  #
  # The project row is locked first so concurrent approvals of two proposals
  # for the same result cannot both miss `existing_meld_node/1` and insert the
  # same commit twice (D7 has no unique index to fall back on).
  defp transition(actor, project_id, proposal_id, decision) do
    _project =
      Repo.one(
        from(p in Project,
          where: p.id == ^project_id,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:not_found)

    proposal =
      Repo.one(
        from(p in Proposal,
          where: p.id == ^proposal_id and p.project_id == ^project_id,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:not_found)

    cond do
      proposal.status == decision ->
        {proposal, nil}

      proposal.status != :pending ->
        Repo.rollback(:invalid_transition)

      decision == :approved and Incidents.blocking_proposal?(proposal.id) ->
        Repo.rollback(:blocked)

      decision == :approved ->
        approve_proposal(proposal, actor)

      true ->
        {decide_status(proposal, actor, decision), nil}
    end
  end

  defp approve_proposal(proposal, actor) do
    case result_integrity(proposal.project_id, proposal) do
      :ok ->
        case materialize(proposal) do
          {:ok, node_id} ->
            {decide_status(proposal, actor, :approved), node_id}

          {:error, reason} ->
            Repo.rollback(reason)
        end

      {:error, reason} ->
        Repo.rollback({:integrity_failed, reason})
    end
  end

  defp materialize(%Proposal{kind: :meld} = proposal), do: attach_meld_node(proposal)

  defp materialize(%Proposal{kind: :promotion} = proposal) do
    with :ok <- pin_target_node(proposal), do: {:ok, nil}
  end

  # The commit SHA is the node's identity (D7), so a second proposal for the
  # same result reuses the node the first one created instead of duplicating it.
  defp attach_meld_node(proposal) do
    case existing_meld_node(proposal) do
      nil ->
        attrs = %{
          project_id: proposal.project_id,
          git_commit_sha: proposal.meld_commit_sha,
          parents: proposal.parent_ids,
          flags: [Meld.intended_flag()],
          pinned: true,
          docs_state: @docs_state,
          created_by: proposal.proposer_id,
          created_at: DateTime.utc_now(),
          message: "Meld of #{length(proposal.parent_ids)} sessions"
        }

        case %Node{} |> Node.changeset(attrs) |> Repo.insert() do
          {:ok, node} -> {:ok, node.id}
          {:error, %Ecto.Changeset{}} -> {:error, :invalid_result_node}
        end

      node ->
        with :ok <- ensure_node_approvable(proposal.project_id, node),
             :ok <- pin_node(node) do
          {:ok, node.id}
        end
    end
  end

  defp pin_target_node(proposal) do
    case Portfolio.node_for_project(proposal.project_id, proposal.target_node_id) do
      nil ->
        {:error, :not_found}

      node ->
        with :ok <- ensure_node_approvable(proposal.project_id, node), do: pin_node(node)
    end
  end

  # Promotion (and reuse of an already materialized meld node) must not move
  # the line onto a node an open critical incident still quarantines (§6.6
  # guards; §6.7 isolation). The incident must be resolved first.
  defp ensure_node_approvable(project_id, node) do
    if Incidents.blocking_node?(project_id, node.id), do: {:error, :blocked}, else: :ok
  end

  defp pin_node(node) do
    node
    |> Ecto.Changeset.change(pinned: true)
    |> Repo.update()
    |> case do
      {:ok, _node} -> :ok
      {:error, %Ecto.Changeset{}} -> {:error, :invalid_result_node}
    end
  end

  defp existing_meld_node(proposal) do
    Repo.one(
      from(n in Node,
        where:
          n.project_id == ^proposal.project_id and n.git_commit_sha == ^proposal.meld_commit_sha,
        order_by: [asc: n.created_at, asc: n.id],
        limit: 1
      )
    )
  end

  defp decide_status(proposal, actor, decision) do
    proposal
    |> Ecto.Changeset.change(
      status: decision,
      reviewer_id: actor.id,
      decided_at: DateTime.utc_now()
    )
    |> Repo.update()
    |> case do
      {:ok, proposal} -> proposal
      {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(changeset)
    end
  end

  defp broadcast_decision(proposal, node_id) do
    topic = "project:#{proposal.project_id}"

    Phoenix.PubSub.broadcast(
      Cadence.Server.PubSub,
      topic,
      {:proposal_decided, proposal.project_id, proposal.id, proposal.status}
    )

    if node_id do
      Phoenix.PubSub.broadcast(
        Cadence.Server.PubSub,
        topic,
        {:nodes_pushed, proposal.project_id, [node_id]}
      )
    end

    :ok
  end

  # The incident is outside the rolled-back transaction on purpose: it is the
  # record that keeps an unverifiable result unapprovable (spec §6.7).
  defp open_integrity_incident(project_id, proposal_id, reason) do
    _ =
      Incidents.open(%{
        project_id: project_id,
        proposal_id: proposal_id,
        kind: :scan_incomplete,
        severity: :critical,
        title: "Meld result could not be verified",
        details: %{stage: :approval_integrity, reason: reason}
      })

    :ok
  end

  defp check_result_tree(repo, commit_sha, result_tree_sha) do
    case GitStore.read_commit(repo, commit_sha) do
      nil ->
        {:error, :missing_objects}

      %{tree: tree} ->
        if tree == result_tree_sha, do: :ok, else: {:error, :tree_mismatch}
    end
  end

  defp cast_sha(sha) when is_binary(sha) do
    if Regex.match?(~r/^[0-9a-f]{40}$/, sha), do: {:ok, sha}, else: {:error, :not_a_commit}
  end

  defp cast_sha(_sha), do: {:error, :not_a_commit}

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
