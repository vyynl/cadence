defmodule Cadence.Server.ProposalView do
  @moduledoc """
  Read-only projections for the public proposal page (spec §6.6, §7.6).

  This module never mutates, never looks up identities, and never logs
  proposal content or tokens. Result content is bounded by the same scan caps
  as the public repository browser. Paths are filtered individually (with a
  generic count) and a secret value in a visible result file quarantines the
  whole result — see spec §7.6, "Proposal results (4a-2)".

  The diff is file-level and relative to the **first** parent; parent
  selection and line-level diffs belong to the review UI (4c).

  `verify_resolution/1` is the incident-resolution counterpart: it re-scans a
  proposal's stored result, so a proposal incident cannot be clicked away while
  the result is still risky (spec §6.7). It mutates nothing.
  """

  import Ecto.Query

  alias Cadence.Server.{
    Incident,
    Incidents,
    Portfolio,
    ProjectGit,
    Proposal,
    Proposals,
    PublicContent,
    Repo
  }

  alias Cadence.Shared.{GitStore, Node, Project}

  # Result of the meld, as produced by `result/3`.
  #
  # `:none` is a promotion (no result tree); isolation is reported by
  # `isolated?/1`, which the caller checks first.
  @type result ::
          :none
          | {:error, :missing_objects | :too_large}
          | {:ok,
             %{
               quarantined?: boolean(),
               truncated?: boolean(),
               hidden_count: non_neg_integer(),
               summary: %{
                 added: non_neg_integer(),
                 modified: non_neg_integer(),
                 deleted: non_neg_integer()
               },
               files: [%{path: String.t(), status: :added | :modified | :deleted}]
             }}

  @doc """
  Parent nodes of a meld proposal, in `parent_ids` order.

  One query, scoped to the proposal's project. Missing parents are omitted, so
  a partially replicated proposal still renders.
  """
  @spec parents(Proposal.t()) :: [Node.t()]
  def parents(%Proposal{kind: :meld, project_id: project_id, parent_ids: parent_ids})
      when is_list(parent_ids) do
    ids = Enum.uniq(parent_ids)

    if ids == [] do
      []
    else
      nodes =
        Repo.all(
          from(n in Node,
            where: n.project_id == ^project_id and n.id in ^ids
          )
        )

      by_id = Map.new(nodes, &{&1.id, &1})
      Enum.flat_map(parent_ids, fn id -> List.wrap(Map.get(by_id, id)) end)
    end
  end

  def parents(%Proposal{}), do: []

  @doc "The promotion target node, scoped to the proposal's project, or `nil`."
  @spec target_node(Proposal.t()) :: Node.t() | nil
  def target_node(%Proposal{
        kind: :promotion,
        project_id: project_id,
        target_node_id: target_node_id
      })
      when is_binary(target_node_id) do
    Repo.get_by(Node, id: target_node_id, project_id: project_id)
  end

  def target_node(%Proposal{}), do: nil

  @doc "Whether an open critical incident isolates this proposal's result."
  @spec isolated?(Proposal.t()) :: boolean()
  def isolated?(%Proposal{id: id}), do: Incidents.blocking_proposal?(id)

  @doc """
  Re-scans the target of an incident before resolution (spec §6.7).

  This is an `Incidents.resolve/4` `:verify` callback. A proposal-linked
  incident only resolves after the stored result passes both checks:

  - the result scans clean under the §7.6 caps — a remaining secret pattern or
    sensitive path is `{:error, :still_risky}`;
  - the result commit's tree still equals `result_tree_sha` and the first
    parent is still reviewable, the same invariants approval enforces
    (`result_integrity/3`). An incident opened by approval integrity therefore
    cannot be acknowledged away while the mismatch holds
    (`{:error, :integrity_failed}`).

  A result that cannot be walked at all (missing objects, not a commit, over
  the caps, or a corrupt store) is `{:error, :unverifiable}`: an unscanned
  result is never "clean". Node, project, and other proposal-less incidents
  resolve by acknowledgment (§6.7, 4b-2) and are always `:ok`, as is a
  promotion, which has no result to scan. Never raises.
  """
  @spec verify_resolution(Incident.t()) ::
          :ok | {:error, :still_risky | :integrity_failed | :unverifiable}
  def verify_resolution(%Incident{proposal_id: nil}), do: :ok

  def verify_resolution(%Incident{} = incident) do
    case Repo.get_by(Proposal, id: incident.proposal_id, project_id: incident.project_id) do
      nil ->
        {:error, :unverifiable}

      %Proposal{kind: :promotion} ->
        :ok

      %Proposal{meld_commit_sha: commit_sha} = proposal ->
        verify_resolution_result(incident.project_id, proposal, commit_sha)
    end
  rescue
    _error -> {:error, :unverifiable}
  catch
    _kind, _value -> {:error, :unverifiable}
  end

  defp verify_resolution_result(project_id, proposal, commit_sha) do
    repo = ProjectGit.open(project_id)

    case walk(repo, commit_sha) do
      {:ok, blobs} ->
        if PublicContent.quarantine?(blobs) do
          {:error, :still_risky}
        else
          resolution_integrity(project_id, proposal)
        end

      {:error, _reason} ->
        {:error, :unverifiable}
    end
  end

  # Resolving must re-assert everything approval enforces, or the incident can
  # be cleared while the result remains unapprovable (resolve → approve →
  # reopen loop). Unscannable/over-cap maps to `unverifiable`; a structural
  # mismatch maps to `integrity_failed`.
  defp resolution_integrity(project_id, proposal) do
    case Proposals.result_integrity(project_id, proposal) do
      :ok -> :ok
      {:error, reason} when reason in [:too_large, :missing_objects] -> {:error, :unverifiable}
      {:error, _reason} -> {:error, :integrity_failed}
    end
  end

  @doc """
  File-level result of the meld, filtered for anonymous visitors.

  Returns `:none` for promotions. The `{:error, :too_large}` case covers a cap
  overflow on either side: an unbounded comparison is never shown. A missing
  parent or result object is `{:error, :missing_objects}` — a partially
  replicated DAG must not be described as "too large".

  Options: `:max_files` overrides the visible-file cap (default from
  `:cadence_server, :proposal_max_files`).
  """
  @spec result(Project.t(), Proposal.t(), keyword()) :: result()
  def result(project, proposal, opts \\ [])

  def result(%Project{}, %Proposal{kind: :promotion}, _opts), do: :none

  def result(%Project{} = project, %Proposal{} = proposal, opts) do
    repo = ProjectGit.open(project.id)

    with {:ok, result_blobs} <- walk(repo, proposal.meld_commit_sha) do
      case walk(repo, first_parent_commit(proposal)) do
        {:ok, parent_blobs} ->
          {:ok, diff(result_blobs, parent_blobs, max_visible_files(opts))}

        {:error, :too_large} ->
          {:error, :too_large}

        {:error, _reason} ->
          {:error, :missing_objects}
      end
    end
  end

  defp first_parent_commit(%Proposal{project_id: project_id, parent_ids: [first | _rest]}) do
    case Repo.get_by(Node, id: first, project_id: project_id) do
      %Node{git_commit_sha: sha} -> sha
      nil -> nil
    end
  end

  defp first_parent_commit(%Proposal{}), do: nil

  defp walk(_repo, nil), do: {:error, :missing_objects}

  defp walk(repo, commit_sha) do
    %{max_files: max_files, max_bytes: max_bytes} = Portfolio.scan_limits()

    case GitStore.walk_blobs(repo, commit_sha, max_files: max_files, max_bytes: max_bytes) do
      {:ok, blobs} -> {:ok, blobs}
      {:error, :too_many_files} -> {:error, :too_large}
      {:error, :too_many_bytes} -> {:error, :too_large}
      {:error, _reason} -> {:error, :missing_objects}
    end
  end

  defp diff(result_blobs, parent_blobs, max_files) do
    old = Map.new(parent_blobs, &{&1.path, &1.ref})
    new = Map.new(result_blobs, &{&1.path, &1.ref})

    changes =
      (Map.keys(old) ++ Map.keys(new))
      |> Enum.uniq()
      |> Enum.reduce([], fn path, acc ->
        change(path, Map.get(old, path), Map.get(new, path), acc)
      end)
      |> Enum.sort_by(& &1.path)

    {visible, hidden_count} = PublicContent.filter_entries(changes)

    %{
      quarantined?: quarantined?(result_blobs),
      truncated?: length(visible) > max_files,
      hidden_count: hidden_count,
      summary: summarize(visible),
      files: Enum.take(visible, max_files)
    }
  end

  defp change(path, nil, _new_ref, acc), do: [%{path: path, status: :added} | acc]
  defp change(path, _old_ref, nil, acc), do: [%{path: path, status: :deleted} | acc]
  defp change(_path, ref, ref, acc), do: acc
  defp change(path, _old_ref, _new_ref, acc), do: [%{path: path, status: :modified} | acc]

  # Paths are filtered individually (with a count); a secret *value* anywhere in
  # the visible result hides the whole result. Blobs behind filtered paths are
  # excluded from the scan because their names are never rendered.
  defp quarantined?(result_blobs) do
    result_blobs
    |> Enum.reject(fn %{path: path} -> hidden_path?(path) end)
    |> PublicContent.quarantine?()
  end

  defp hidden_path?(path) do
    PublicContent.sensitive_path?(path) and not PublicContent.allowed_sensitive_path?(path)
  end

  defp summarize(files) do
    Enum.reduce(files, %{added: 0, modified: 0, deleted: 0}, fn %{status: status}, acc ->
      Map.update!(acc, status, &(&1 + 1))
    end)
  end

  defp max_visible_files(opts) do
    case Keyword.get(opts, :max_files) ||
           Application.get_env(:cadence_server, :proposal_max_files, 200) do
      value when is_integer(value) and value >= 0 -> value
      _other -> 200
    end
  end
end
