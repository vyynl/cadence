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
  status}`. A newly created pending proposal broadcasts
  `{:proposal_created, project_id, proposal_id}` so a review queue can insert it
  without a reload (creation moves no node and no session pointer). Any
  approval that touches a node also broadcasts
  `{:nodes_pushed, project_id, [node_id]}` — a new meld node, a reused meld
  node re-pinned, or a promotion target whose pin changed. Every successful
  decision additionally wakes each project member's daemon through
  `Cadence.Server.SyncNotifier` (`{:sync_available, project_id}`); pinning
  bumps the node's pull cursor so the change is actually pulled. An idempotent
  re-decision repeats `proposal_decided` with the stored status. Nothing is
  broadcast when a decision is refused, and a creation that fails validation or
  authorization broadcasts nothing.
  """

  import Ecto.Query

  require Logger

  alias Cadence.Server.{
    Authorization,
    Incidents,
    Portfolio,
    ProjectGit,
    Proposal,
    Repo,
    Sync,
    SyncNotifier
  }

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
        case Repo.insert(changeset) do
          {:ok, proposal} = ok ->
            broadcast_created(proposal)
            ok

          other ->
            other
        end
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
  be a commit, its tree must be walkable under the §7.6 scan caps (an
  over-cap result is `:too_large`), every reachable object must be present,
  its tree must equal the proposal's `result_tree_sha`, and the first parent
  node and commit must still exist (`:missing_parent`) — a result whose diff
  could never have been shown is not approvable.

  `project_id` must be the project that owns the proposal: it selects the
  object store. Call it with a proposal obtained from `get/3` or
  `get_by_token/1`; passing a client-controlled `project_id` would make it an
  object-store probe. Promotions carry no result and are always `:ok`. Never
  raises, even on a corrupt object store.

  Options: `:max_files` / `:max_bytes` override the scan caps (tests only).
  """
  @spec result_integrity(Ecto.UUID.t() | String.t(), Proposal.t(), keyword()) ::
          :ok
          | {:error,
             :missing_objects | :tree_mismatch | :not_a_commit | :too_large | :missing_parent}
  def result_integrity(project_id, proposal, opts \\ [])

  def result_integrity(_project_id, %Proposal{kind: :promotion}, _opts), do: :ok

  def result_integrity(project_id, %Proposal{kind: :meld} = proposal, opts) do
    with {:ok, commit_sha} <- cast_sha(proposal.meld_commit_sha),
         :ok <- verify_result(project_id, commit_sha, proposal.result_tree_sha, opts),
         :ok <- verify_first_parent(project_id, proposal) do
      :ok
    end
  end

  def result_integrity(_project_id, _proposal, _opts), do: {:error, :missing_objects}

  # The reviewer's diff walks the first parent under the scan caps; a missing
  # node, commit, tree, or blob means the result was never reviewable, so
  # approval fails closed.
  defp verify_first_parent(project_id, %Proposal{parent_ids: [first | _rest]}) do
    repo = ProjectGit.open(project_id)
    limits = Portfolio.scan_limits()

    with %Node{git_commit_sha: commit_sha} <-
           Repo.get_by(Node, id: first, project_id: project_id),
         {:ok, _blobs} <-
           GitStore.walk_blobs(repo, commit_sha,
             max_files: limits.max_files,
             max_bytes: limits.max_bytes
           ) do
      :ok
    else
      _other -> {:error, :missing_parent}
    end
  rescue
    _error -> {:error, :missing_parent}
  catch
    _kind, _value -> {:error, :missing_parent}
  end

  defp verify_first_parent(_project_id, %Proposal{}), do: {:error, :missing_parent}

  # The store holds untrusted bytes: a structurally corrupt but decompressible
  # object can raise inside the decoder. Integrity is a fence, so anything
  # unexpected fails closed as "objects missing" instead of escaping.
  defp verify_result(project_id, commit_sha, result_tree_sha, opts) do
    repo = ProjectGit.open(project_id)
    limits = Portfolio.scan_limits()

    case GitStore.walk_blobs(repo, commit_sha,
           max_files: Keyword.get(opts, :max_files, limits.max_files),
           max_bytes: Keyword.get(opts, :max_bytes, limits.max_bytes)
         ) do
      {:ok, _blobs} -> check_result_tree(repo, commit_sha, result_tree_sha)
      {:error, :too_many_files} -> {:error, :too_large}
      {:error, :too_many_bytes} -> {:error, :too_large}
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
  The node approval would attach or pin for a pending proposal, if one already
  exists.

  Mirrors the node `ensure_node_approvable/2` checks: a promotion's target
  node, or the existing node carrying a meld's result commit (a first-time meld
  creates a fresh node, which no incident can quarantine yet). `nil` means the
  decision has no pre-existing node that an incident could block.
  """
  @spec decision_node(Proposal.t()) :: Node.t() | nil
  def decision_node(%Proposal{kind: :promotion, project_id: project_id, target_node_id: id})
      when is_binary(id) do
    Portfolio.node_for_project(project_id, id)
  end

  def decision_node(%Proposal{kind: :meld} = proposal), do: existing_meld_node(proposal)
  def decision_node(%Proposal{}), do: nil

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
        {:ok, {proposal, attachment}} ->
          # The pin is committed; bumping the pull cursor afterwards (not inside
          # the transaction) means a concurrent pull can never advance past a
          # sequence value that was allocated before this commit.
          touch_pin(attachment)
          broadcast_decision(proposal, attachment)
          {:ok, proposal}

        {:error, {:integrity_failed, reason}} ->
          open_integrity_incident(project_id, proposal_id, reason)
          {:error, :integrity_failed}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Returns `{proposal, attachment | nil}` where an attachment is
  # `%{node_id, created?, pin_changed?}`. Only a fresh meld approval creates a
  # node; a reused meld node or a promotion reports whether the pin actually
  # flipped, so `nodes_pushed` means "node changed" and no redundant cursor
  # bumps happen. Idempotent re-decisions and rejections attach nothing.
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
          {:ok, attachment} ->
            {decide_status(proposal, actor, :approved), attachment}

          {:error, reason} ->
            Repo.rollback(reason)
        end

      {:error, reason} ->
        Repo.rollback({:integrity_failed, reason})
    end
  end

  defp materialize(%Proposal{kind: :meld} = proposal), do: attach_meld_node(proposal)

  defp materialize(%Proposal{kind: :promotion} = proposal) do
    with {:ok, node, pin_changed?} <- pin_target_node(proposal) do
      {:ok, %{node_id: node.id, created?: false, pin_changed?: pin_changed?}}
    end
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
          {:ok, node} -> {:ok, %{node_id: node.id, created?: true, pin_changed?: false}}
          {:error, %Ecto.Changeset{}} -> {:error, :invalid_result_node}
        end

      node ->
        with :ok <- ensure_node_approvable(proposal.project_id, node),
             {:ok, pin_changed?} <- pin_node(node) do
          {:ok, %{node_id: node.id, created?: false, pin_changed?: pin_changed?}}
        end
    end
  end

  defp pin_target_node(proposal) do
    case Portfolio.node_for_project(proposal.project_id, proposal.target_node_id) do
      nil ->
        {:error, :not_found}

      node ->
        with :ok <- ensure_node_approvable(proposal.project_id, node),
             {:ok, pin_changed?} <- pin_node(node) do
          {:ok, node, pin_changed?}
        end
    end
  end

  # Promotion (and reuse of an already materialized meld node) must not move
  # the line onto a node an open critical incident still quarantines (§6.6
  # guards; §6.7 isolation). The incident must be resolved first.
  defp ensure_node_approvable(project_id, node) do
    if Incidents.blocking_node?(project_id, node.id), do: {:error, :blocked}, else: :ok
  end

  # Pinned is server-authoritative and mutable. Returns whether the value
  # actually changed; the post-commit `touch_pin/1` bumps the pull cursor.
  defp pin_node(%Node{pinned: true}), do: {:ok, false}

  defp pin_node(node) do
    case node |> Ecto.Changeset.change(pinned: true) |> Repo.update() do
      {:ok, _updated} -> {:ok, true}
      {:error, %Ecto.Changeset{}} -> {:error, :invalid_result_node}
    end
  end

  # Best-effort: the decision is already committed, so a failed cursor bump
  # must not fail the approval. Daemons converge on the next change or poll.
  defp touch_pin(nil), do: :ok
  defp touch_pin(%{pin_changed?: false}), do: :ok

  defp touch_pin(%{node_id: node_id}) do
    case Sync.touch_node(node_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("could not bump the pull cursor for node #{node_id}: #{inspect(reason)}")
        :ok
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

  defp broadcast_decision(proposal, attachment) do
    topic = "project:#{proposal.project_id}"

    Phoenix.PubSub.broadcast(
      Cadence.Server.PubSub,
      topic,
      {:proposal_decided, proposal.project_id, proposal.id, proposal.status}
    )

    if node_changed?(attachment) do
      Phoenix.PubSub.broadcast(
        Cadence.Server.PubSub,
        topic,
        {:nodes_pushed, proposal.project_id, [attachment.node_id]}
      )
    end

    # Every decision wakes each member's daemon: a meld adds a node, a
    # promotion changes `pinned`, and a rejection changes review state only
    # (a harmless extra poll). A refused decision never reaches this function.
    SyncNotifier.project_changed(proposal.project_id)

    :ok
  end

  # Creation is live queue state only: no node moves, so no daemon needs waking.
  # Best-effort like the decision broadcast — the row is already committed.
  defp broadcast_created(proposal) do
    Phoenix.PubSub.broadcast(
      Cadence.Server.PubSub,
      "project:#{proposal.project_id}",
      {:proposal_created, proposal.project_id, proposal.id}
    )

    :ok
  rescue
    error ->
      Logger.warning("proposal broadcast failed: #{inspect(error.__struct__)}")
      :ok
  catch
    kind, _reason ->
      Logger.warning("proposal broadcast failed: #{inspect(kind)}")
      :ok
  end

  defp node_changed?(nil), do: false
  defp node_changed?(%{created?: true}), do: true
  defp node_changed?(%{pin_changed?: true}), do: true
  defp node_changed?(_attachment), do: false

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
