defmodule Cadence.Daemon.Unions do
  @moduledoc """
  Local journal of union proposals created from this daemon (spec §6.5).

  The server owns proposals and their decisions. This context only keeps the
  reference returned by `POST /sync/union` so `:CadProposals` can recover the
  public token; `status` is the state at creation and is never refreshed.

  Rows are keyed by the server proposal ID (identity-mapped) and capped at
  20 per project. `record/3` is best-effort at the call site: a failure must
  never fail the union itself.
  """

  import Ecto.Query

  alias Cadence.Daemon.{Repo, UnionProposal}
  alias Cadence.Shared.UUID

  @limit 20

  @doc """
  Records a union response for a project.

  Upserts by proposal ID so a repeated submit for the same ordered parents
  (which the server dedupes) updates one row instead of creating another; the
  original `created_at` is kept. Prunes the project's journal to the newest
  20 rows in the same transaction.

  Returns `{:error, :invalid_proposal}` for an unusable response (missing/invalid
  project, proposal ID, token, or parent ID) without writing anything.
  """
  @spec record(Ecto.UUID.t(), map(), [Ecto.UUID.t()]) ::
          {:ok, UnionProposal.t()} | {:error, :invalid_proposal | Ecto.Changeset.t()}
  def record(project_id, proposal, parent_node_ids) do
    with {:ok, project_id} <- UUID.cast(project_id),
         {:ok, proposal_id} <- cast_proposal_id(proposal),
         {:ok, token} <- cast_token(proposal),
         {:ok, parents} <- cast_parents(parent_node_ids) do
      attrs = %{
        id: proposal_id,
        project_id: project_id,
        token: token,
        kind: string_field(proposal, :kind),
        status: string_field(proposal, :status),
        parent_node_ids: parents,
        created_at: DateTime.utc_now()
      }

      Repo.transaction(fn ->
        case %UnionProposal{}
             |> UnionProposal.changeset(attrs)
             |> Repo.insert(
               on_conflict: {:replace, [:token, :kind, :status, :parent_node_ids]},
               conflict_target: :id,
               log: false
             ) do
          {:ok, _inserted} ->
            # Read before pruning: a re-submitted proposal older than the cap is
            # removed by the prune, and reading afterwards would raise.
            row = Repo.get!(UnionProposal, proposal_id)
            prune(project_id)
            row

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    else
      :error -> {:error, :invalid_proposal}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  The project's recorded proposals, newest first.

  An invalid project ID or a non-positive limit returns `[]` (the socket API
  validates the project before calling this).
  """
  @spec list(Ecto.UUID.t(), pos_integer()) :: [UnionProposal.t()]
  def list(project_id, limit \\ @limit) do
    with {:ok, project_id} <- UUID.cast(project_id),
         true <- is_integer(limit) and limit > 0 do
      UnionProposal
      |> where([p], p.project_id == ^project_id)
      |> order_by([p], desc: p.created_at, desc: p.id)
      |> limit(^limit)
      |> Repo.all()
    else
      _ -> []
    end
  end

  @doc """
  Fetches a recorded proposal by ID or public token, scoped to the project.

  Returns `nil` for an unknown project, ID, or token.
  """
  @spec get(Ecto.UUID.t(), String.t()) :: UnionProposal.t() | nil
  def get(project_id, id_or_token) do
    with {:ok, project_id} <- UUID.cast(project_id),
         true <- is_binary(id_or_token) and id_or_token != "" do
      case UUID.cast(id_or_token) do
        {:ok, id} ->
          Repo.one(
            from(p in UnionProposal,
              where: p.project_id == ^project_id and (p.id == ^id or p.token == ^id_or_token)
            )
          )

        :error ->
          Repo.one(
            from(p in UnionProposal,
              where: p.project_id == ^project_id and p.token == ^id_or_token
            )
          )
      end
    else
      _ -> nil
    end
  end

  defp prune(project_id) do
    keep =
      from(p in UnionProposal,
        where: p.project_id == ^project_id,
        order_by: [desc: p.created_at, desc: p.id],
        limit: @limit,
        select: p.id
      )

    from(p in UnionProposal,
      where: p.project_id == ^project_id and p.id not in subquery(keep)
    )
    |> Repo.delete_all()
  end

  defp cast_proposal_id(%{proposal_id: id}) do
    case UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_proposal}
    end
  end

  defp cast_proposal_id(_proposal), do: {:error, :invalid_proposal}

  defp cast_token(%{proposal_token: token}) when is_binary(token) and token != "" do
    if String.length(token) <= 255 do
      {:ok, token}
    else
      {:error, :invalid_proposal}
    end
  end

  defp cast_token(_proposal), do: {:error, :invalid_proposal}

  defp cast_parents(ids) when is_list(ids) do
    ids
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
      case UUID.cast(id) do
        {:ok, id} -> {:cont, {:ok, [id | acc]}}
        :error -> {:halt, {:error, :invalid_proposal}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp cast_parents(_ids), do: {:error, :invalid_proposal}

  defp string_field(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end
end
