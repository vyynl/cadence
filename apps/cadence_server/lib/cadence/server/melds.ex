defmodule Cadence.Server.Melds do
  @moduledoc """
  Server-side meld pipeline: propose, don't create (spec §6.5, §6.6, §9).

  The pipeline is deterministic first and AI-assisted second:

  1. authorize the proposer and load the project and parent nodes;
  2. walk each parent snapshot under the public scan caps;
  3. compute the union of all parents (`Cadence.Shared.Meld`);
  4. ask the model **only** about conflicting paths;
  5. parse and validate the operations, refuse binary content, and
     syntax-check Elixir files;
  6. materialize the result tree/commit and create a **pending proposal**.

  No node is created and no flag is promoted here: `intended_flag` is always
  `"in-progress"` and `functioning` stays validator-owned (spec §3.1). Approval
  and node creation belong to the review slice.

  Failures open redacted incidents and return an error instead of a proposal.
  `details` never contains file content, prompts, completions, or secret
  values. Repeated failures reuse the open incident for the same project and
  kind.

  ## Result metadata

  `proposals.result_metadata` is written after insert with string keys so the
  jsonb round-trip is stable:

      %{
        "generated_at" => iso8601,
        "provider" => provider or nil,
        "model" => model or nil,
        "prompt_version" => "meld-v1",
        "llm" => "used" | "skipped_no_conflicts",
        "parent_count" => n,
        "conflict_count" => n,
        "file_count" => n,
        "ops" => %{"create" => n, "modify" => n, "delete" => n},
        "intended_flag" => "in-progress"
      }

  ## Return contract

      {:ok, Proposal.t()}
      | {:error, :not_found | :forbidden | :invalid_parent
                | {:scan, term()} | {:meld, term()}
                | :invalid_agent_output | Ecto.Changeset.t()}

  Every failure either opens an incident or is a pure input/authorization
  error. `{:error, :invalid_agent_output}` covers malformed, out-of-allowlist,
  binary, or syntactically invalid model output. `{:error, {:meld, reason}}`
  covers a provider failure (`:not_configured`, `:timeout`, `:rate_limited`,
  `:llm`, `:exit`); `:context_too_large` opens a critical `scan_incomplete`
  incident because the model was never called.
  """

  import Ecto.Query

  alias Cadence.Server.{
    Accounts,
    Authorization,
    Incidents,
    MeldWorker,
    Portfolio,
    ProjectGit,
    Proposal,
    Proposals,
    PublicContent,
    Repo
  }

  alias Cadence.Shared.{GitStore, Meld, Node, Project, UUID}
  alias Cadence.Shared.LLM
  alias Cadence.Shared.LLM.Meld, as: MeldPrompt

  @default_author %{name: "Cadence", email: "cadence@localhost"}

  # Each parent can retain up to the full scan cap in memory, so the list is
  # capped well below anything a real DAG merge needs (spec §6.5).
  @max_parents 8

  @doc """
  Builds a pending meld proposal for `actor` from `parent_ids`.

  Owners and trusted members may propose. Parents must be 2..8 distinct nodes
  of the same project. The result commit's parents are the parent nodes'
  commits, in `parent_ids` order.

  Queue dedupe: when a pending meld proposal already exists for the same
  ordered `parent_ids` in the project, it is returned unchanged instead of
  running the union again (rejected work is re-submitted as a new proposal).
  """
  @spec propose(map(), Ecto.UUID.t() | String.t(), [Ecto.UUID.t() | String.t()]) ::
          {:ok, Cadence.Server.Proposal.t()}
          | {:error,
             :not_found
             | :forbidden
             | :invalid_parent
             | {:scan, term()}
             | {:meld, term()}
             | :invalid_agent_output
             | Ecto.Changeset.t()}
  def propose(actor, project_id, parent_ids) do
    with {:ok, project_id} <- uuid(project_id),
         {:ok, project} <- fetch_project(project_id),
         {:ok, _membership} <- authorize_proposer(actor, project_id),
         {:ok, parents} <- load_parents(project, parent_ids) do
      case pending_meld(project.id, Enum.map(parents, & &1.id)) do
        %Proposal{} = pending ->
          {:ok, pending}

        nil ->
          with {:ok, walked} <- walk_parents(project, parents) do
            union = Meld.union(walked)
            resolve(project, actor, parents, walked, union)
          end
      end
    end
  end

  defp pending_meld(project_id, parent_ids) do
    Repo.one(
      from(p in Proposal,
        where:
          p.project_id == ^project_id and p.kind == :meld and p.status == :pending and
            p.parent_ids == ^parent_ids,
        order_by: [desc: p.created_at, desc: p.id],
        limit: 1
      )
    )
  end

  ## Union and model resolution

  defp resolve(project, actor, parents, walked, union) do
    if map_size(union.conflicts) == 0 do
      files = content_map(union.agreed)

      create_proposal(project, actor, parents, union, %{
        files: files,
        ops: [],
        llm: %{
          mode: "skipped_no_conflicts",
          provider: LLM.provider(),
          model: LLM.model(),
          prompt_version: MeldPrompt.prompt_version()
        }
      })
    else
      with :ok <- reject_binary_conflicts(project, union),
           {:ok, result} <- resolve_with_model(project, walked, union) do
        apply_model_output(project, actor, parents, union, result)
      end
    end
  end

  defp resolve_with_model(project, walked, union) do
    case MeldWorker.resolve(walked, union.conflicts, scope: project.id) do
      {:ok, result} ->
        {:ok, result}

      {:error, :context_too_large} ->
        open_incident(project, :scan_incomplete, :critical, "Meld context too large", %{
          stage: :prompt,
          reason: :context_too_large
        })

        {:error, {:meld, :context_too_large}}

      {:error, reason} ->
        open_incident(project, :meld_failed, :high, "Meld agent failed", %{
          stage: :llm,
          reason: meld_reason(reason)
        })

        {:error, {:meld, reason}}
    end
  end

  defp reject_binary_conflicts(project, union) do
    binary? =
      Enum.any?(union.conflicts, fn {_path, versions} ->
        Enum.any?(versions, &PublicContent.binary?(&1.content))
      end)

    if binary? do
      invalid_output(project, %{stage: :conflict, reason: :binary_content})
    else
      :ok
    end
  end

  defp apply_model_output(project, actor, parents, union, result) do
    with {:ok, ops} <- parse_ops(project, result.text, union.conflicts),
         {:ok, files} <- apply_ops(project, union, ops),
         :ok <- validate_ops(project, ops) do
      create_proposal(project, actor, parents, union, %{
        files: files,
        ops: ops,
        llm: %{
          mode: "used",
          provider: result.provider,
          model: result.model,
          prompt_version: result.prompt_version
        }
      })
    end
  end

  defp parse_ops(project, text, conflicts) do
    case MeldPrompt.parse(text, Map.keys(conflicts),
           max_ops: config_int(:meld_max_ops, 50),
           max_file_bytes: config_int(:meld_max_file_bytes, 262_144)
         ) do
      {:ok, ops} -> {:ok, ops}
      {:error, reason} -> invalid_output(project, %{stage: :parse, reason: reason})
    end
  end

  defp apply_ops(project, union, ops) do
    case Meld.apply_ops(union, ops,
           max_ops: config_int(:meld_max_ops, 50),
           max_file_bytes: config_int(:meld_max_file_bytes, 262_144)
         ) do
      {:ok, files} -> {:ok, files}
      {:error, reason} -> invalid_output(project, %{stage: :apply, reason: reason})
    end
  end

  # The model's output is never trusted: binary content can never be written,
  # and Elixir files must at least parse. Other languages are reviewer-checked.
  defp validate_ops(project, ops) do
    Enum.reduce_while(ops, :ok, fn
      {_kind, path, content}, :ok ->
        cond do
          PublicContent.binary?(content) ->
            {:halt, invalid_output(project, %{stage: :validation, reason: :binary_content})}

          not elixir_syntax_valid?(path, content) ->
            {:halt, invalid_output(project, %{stage: :validation, reason: :syntax_error})}

          true ->
            {:cont, :ok}
        end

      {:delete, _path}, :ok ->
        {:cont, :ok}
    end)
  end

  defp elixir_syntax_valid?(path, content) do
    if String.ends_with?(path, [".ex", ".exs"]) do
      match?({:ok, _ast}, Code.string_to_quoted(content))
    else
      true
    end
  end

  ## Materialization and proposal

  defp create_proposal(project, actor, parents, union, %{files: files, ops: ops, llm: llm}) do
    repo = ProjectGit.init(project.id)
    parent_shas = Enum.map(parents, & &1.git_commit_sha)

    with {:ok, tree} <- put_files(project, repo, files),
         commit <-
           GitStore.write_commit(
             repo,
             tree,
             parent_shas,
             author(actor),
             "Meld of #{length(parents)} sessions"
           ),
         {:ok, proposal} <-
           Proposals.create(actor, %{
             project_id: project.id,
             kind: :meld,
             parent_ids: Enum.map(parents, & &1.id),
             result_tree_sha: tree,
             meld_commit_sha: commit
           }),
         {:ok, proposal} <- write_metadata(proposal, parents, union, ops, files, llm) do
      open_secret_incident(proposal, files)
      {:ok, proposal}
    end
  end

  defp put_files(project, repo, files) do
    case GitStore.put_files(repo, files) do
      {:ok, tree} -> {:ok, tree}
      {:error, reason} -> invalid_output(project, %{stage: :materialize, reason: reason})
    end
  end

  defp write_metadata(proposal, parents, union, ops, files, llm) do
    metadata = %{
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "provider" => llm.provider,
      "model" => llm.model,
      "prompt_version" => llm.prompt_version,
      "llm" => llm.mode,
      "parent_count" => length(parents),
      "conflict_count" => map_size(union.conflicts),
      "file_count" => map_size(files),
      "ops" => ops_counts(ops),
      "intended_flag" => Atom.to_string(Meld.intended_flag())
    }

    proposal
    |> Ecto.Changeset.change(result_metadata: metadata)
    |> Repo.update()
  end

  defp ops_counts(ops) do
    Enum.reduce(ops, %{"create" => 0, "modify" => 0, "delete" => 0}, fn op, acc ->
      kind = op |> elem(0) |> Atom.to_string()
      Map.update!(acc, kind, &(&1 + 1))
    end)
  end

  defp open_secret_incident(proposal, files) do
    blobs = Enum.map(files, fn {path, content} -> %{path: path, content: content} end)

    if PublicContent.quarantine?(blobs) do
      patterns =
        blobs
        |> Enum.flat_map(&PublicContent.findings(&1.content))
        |> Enum.uniq()
        |> Enum.sort()

      sensitive_paths =
        Enum.count(blobs, fn %{path: path} ->
          PublicContent.sensitive_path?(path) and not PublicContent.allowed_sensitive_path?(path)
        end)

      open_incident(proposal, :secret_detected, :critical, "Secret detected in meld result", %{
        patterns: patterns,
        sensitive_paths: sensitive_paths
      })
    end

    :ok
  end

  defp open_incident(%Proposal{} = proposal, kind, severity, title, details) do
    open_incident(
      %{project_id: proposal.project_id, proposal_id: proposal.id},
      kind,
      severity,
      title,
      details
    )
  end

  defp open_incident(%Project{} = project, kind, severity, title, details) do
    open_incident(%{project_id: project.id}, kind, severity, title, details)
  end

  defp open_incident(attrs, kind, severity, title, details) when is_map(attrs) do
    attrs =
      Map.merge(attrs, %{
        kind: kind,
        severity: severity,
        title: title,
        details: details
      })

    # Incident bookkeeping must never turn a meld failure into a crash.
    _ = Incidents.open(attrs)
    :ok
  end

  defp invalid_output(project, details) do
    open_incident(project, :agent_output_invalid, :high, "Meld agent output rejected", details)
    {:error, :invalid_agent_output}
  end

  defp meld_reason({:rate_limited, _ms}), do: :rate_limited
  defp meld_reason({:llm, _reason}), do: :llm_error
  defp meld_reason({:exit, _reason}), do: :agent_exit
  defp meld_reason(reason) when is_atom(reason), do: reason
  defp meld_reason(_reason), do: :unknown

  ## Parents and authorization

  defp load_parents(project, parent_ids) do
    with true <- is_list(parent_ids),
         {:ok, ids} <- cast_ids(parent_ids),
         true <- valid_parent_count?(ids) do
      nodes =
        Repo.all(
          from(n in Node,
            where: n.project_id == ^project.id and n.id in ^ids
          )
        )

      by_id = Map.new(nodes, &{&1.id, &1})

      if length(nodes) == length(ids) do
        {:ok, Enum.map(ids, &Map.fetch!(by_id, &1))}
      else
        {:error, :invalid_parent}
      end
    else
      _other -> {:error, :invalid_parent}
    end
  end

  defp valid_parent_count?(ids) do
    count = length(ids)
    count >= 2 and count <= @max_parents and length(Enum.uniq(ids)) == count
  end

  defp cast_ids(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case UUID.cast(id) do
        {:ok, uuid} -> {:cont, {:ok, [uuid | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp walk_parents(project, parents) do
    %{max_files: max_files, max_bytes: max_bytes} = Portfolio.scan_limits()
    repo = ProjectGit.open(project.id)

    parents
    |> Enum.reduce_while({:ok, []}, fn parent, {:ok, acc} ->
      case GitStore.walk_blobs(repo, parent.git_commit_sha,
             max_files: max_files,
             max_bytes: max_bytes
           ) do
        {:ok, blobs} ->
          files =
            Map.new(blobs, fn %{path: path, ref: ref, content: content} ->
              {path, %{ref: ref, content: content}}
            end)

          walked = %{
            id: parent.id,
            message: parent.message,
            flags: parent.flags,
            files: files
          }

          {:cont, {:ok, [walked | acc]}}

        {:error, reason} ->
          {:halt, scan_failure(project, reason)}
      end
    end)
    |> case do
      {:ok, walked} -> {:ok, Enum.reverse(walked)}
      error -> error
    end
  end

  defp scan_failure(project, reason) when reason in [:too_many_files, :too_many_bytes] do
    open_incident(project, :scan_incomplete, :critical, "Meld parent scan incomplete", %{
      stage: :parent_scan,
      reason: reason
    })

    {:error, {:scan, reason}}
  end

  defp scan_failure(project, reason) do
    open_incident(project, :missing_objects, :high, "Meld parent objects missing", %{
      stage: :parent_scan,
      reason: reason
    })

    {:error, {:scan, reason}}
  end

  defp author(actor) do
    actor_id = to_string(actor.id)

    case Accounts.users_by_ids([actor_id]) do
      %{^actor_id => %{name: name, email: email}} when is_binary(name) and name != "" ->
        %{name: name, email: to_string(email)}

      _other ->
        @default_author
    end
  end

  defp content_map(agreed) do
    Map.new(agreed, fn {path, %{content: content}} -> {path, content} end)
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

  defp config_int(key, default) do
    case Application.get_env(:cadence_server, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _other -> default
    end
  end
end
