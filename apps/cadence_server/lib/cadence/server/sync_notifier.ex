defmodule Cadence.Server.SyncNotifier do
  @moduledoc """
  Fan-out of `sync_available` hints to daemons (spec §10.5).

  Daemons join `sync:user:<server_user_id>`; a project change must reach every
  member's daemons, not only the user who triggered it, or a pushed node, an
  approved meld, or a promotion pin waits for the next poll tick. The payload
  carries a project id only — never DAG or preference state — because HTTP
  polling remains the correctness path.

  Best-effort: the caller's write is already committed, so a notification
  failure is logged (shape only) and swallowed.
  """

  import Ecto.Query

  require Logger

  alias Cadence.Server.Repo
  alias Cadence.Shared.{Membership, UUID}

  @doc """
  Wakes every member's daemon for `project_id`.

  Unknown or malformed ids are a no-op: a notification must never fail the
  caller's write.
  """
  @spec project_changed(Ecto.UUID.t() | String.t()) :: :ok
  def project_changed(project_id) do
    case UUID.cast(project_id) do
      {:ok, project_id} ->
        try do
          membership_user_ids(project_id)
          |> Enum.each(&broadcast(&1, project_id))
        rescue
          error ->
            Logger.warning("sync notification failed: #{inspect(error.__struct__)}")
            :ok
        end

      :error ->
        :ok
    end
  end

  @doc "Wakes one user's daemon for `project_id` (per-user writes such as preferences)."
  @spec user_changed(Ecto.UUID.t() | String.t(), Ecto.UUID.t() | String.t()) :: :ok
  def user_changed(user_id, project_id) do
    with {:ok, user_id} <- UUID.cast(user_id),
         {:ok, project_id} <- UUID.cast(project_id) do
      broadcast(user_id, project_id)
    else
      _other -> :ok
    end
  end

  defp membership_user_ids(project_id) do
    Repo.all(
      from(m in Membership,
        where: m.project_id == ^project_id,
        select: m.user_id
      )
    )
  end

  defp broadcast(user_id, project_id) do
    Phoenix.PubSub.broadcast(
      Cadence.Server.PubSub,
      "sync:user:#{user_id}",
      {:sync_available, project_id}
    )

    :ok
  end
end
