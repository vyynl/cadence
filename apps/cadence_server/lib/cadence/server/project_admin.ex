defmodule Cadence.Server.ProjectAdmin do
  @moduledoc """
  Owner-level project mutations from the web UI.

  Authorization lives in the LiveView/controller boundary; this context only
  performs the validated database update.

  `pinned` is server-authoritative and mutable. An actual change bumps the
  node's pull cursor (`Cadence.Server.Sync.touch_node/1`) and wakes members'
  daemons (`Cadence.Server.SyncNotifier`), so daemons converge without a
  full re-pull (spec §10.3, §10.5). Setting the current value is a no-op.

  The cursor bump runs **after** the pin transaction commits: `nextval` values
  are not visible until commit, so bumping inside the transaction could hand
  out a sequence value below a cursor another pull already advanced past.
  Bumping afterwards guarantees the next pull sees the changed row.
  """

  import Ecto.Query

  require Logger

  alias Cadence.Server.{Portfolio, Repo, Sync, SyncNotifier}
  alias Cadence.Shared.Node

  @doc "Set a node's pinned flag, ensuring it belongs to the project."
  @spec set_pinned(Ecto.UUID.t() | String.t(), Ecto.UUID.t() | String.t(), boolean()) ::
          {:ok, Node.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def set_pinned(project_id, node_id, pinned) when is_boolean(pinned) do
    case Portfolio.node_for_project(project_id, node_id) do
      nil ->
        {:error, :not_found}

      _node ->
        result =
          Repo.transaction(fn ->
            locked =
              Repo.one(
                from(n in Node,
                  where: n.project_id == ^project_id and n.id == ^node_id,
                  lock: "FOR UPDATE"
                )
              ) || Repo.rollback(:not_found)

            if locked.pinned == pinned do
              {locked, false}
            else
              case locked |> Ecto.Changeset.change(pinned: pinned) |> Repo.update() do
                {:ok, updated} -> {updated, true}
                {:error, changeset} -> Repo.rollback(changeset)
              end
            end
          end)

        finish(result)
    end
  end

  def set_pinned(_project_id, _node_id, _pinned), do: {:error, :not_found}

  defp finish({:ok, {node, false}}), do: {:ok, node}

  defp finish({:ok, {node, true}}) do
    # Committed already; a failed bump must not turn a successful pin into an
    # error. Convergence catches up on the next change or poll.
    case Sync.touch_node(node.id) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("pin cursor bump failed: #{inspect(reason)}")
    end

    SyncNotifier.project_changed(node.project_id)
    {:ok, node}
  end

  defp finish({:error, reason}), do: {:error, reason}
end
