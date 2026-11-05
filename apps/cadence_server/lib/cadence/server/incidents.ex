defmodule Cadence.Server.Incidents do
  @moduledoc """
  Critical findings that isolate risky content and block promotion until a
  human resolves them (spec §6.7).

  Incidents are opened by server-side detection (meld creation or push scans)
  and resolved by an owner or granted approver. Resolution re-runs the supplied
  verification callback; a still-risky target stays open.
  """

  import Ecto.Query

  alias Cadence.Server.{Authorization, Incident, Repo}
  alias Cadence.Shared.{Project, UUID}

  # Critical incidents sort first, so the cap can only hide lower-severity
  # alerts, never a blocking one. Keeps the review panel bounded (§7.2).
  @max_open_incidents 50

  @doc """
  Opens an incident, returning the existing open incident when the same target
  and kind are already open.

  Internal: callers must have already validated the target and must never put
  secret values in `details`.
  """
  @spec open(map()) :: {:ok, Incident.t()} | {:error, Ecto.Changeset.t()}
  def open(attrs) when is_map(attrs) do
    case %Incident{} |> Incident.changeset(attrs) |> Repo.insert() do
      {:ok, incident} ->
        {:ok, incident}

      {:error, %Ecto.Changeset{} = changeset} ->
        case existing_open_incident(changeset) do
          nil -> {:error, changeset}
          incident -> {:ok, incident}
        end
    end
  end

  @doc """
  List a project's open incidents, critical first and newest first.

  Returns at most `max_open_incidents/0` rows; critical incidents sort first,
  so the cap only hides lower-severity alerts.
  """
  @spec list_open(map(), Ecto.UUID.t() | String.t()) ::
          {:ok, [Incident.t()]} | {:error, :not_found | :forbidden}
  def list_open(actor, project_id) do
    with {:ok, project_id} <- uuid(project_id),
         {:ok, _project} <- fetch_project(project_id),
         {:ok, _membership} <- authorize_viewer(actor, project_id) do
      {:ok,
       Repo.all(
         from(i in Incident,
           where: i.project_id == ^project_id and i.status == :open,
           order_by: [
             asc: fragment("CASE WHEN severity = 'critical' THEN 0 ELSE 1 END"),
             desc: i.created_at,
             desc: i.id
           ],
           limit: @max_open_incidents
         )
       )}
    end
  end

  @doc "The maximum number of open incidents returned by `list_open/2`."
  @spec max_open_incidents() :: pos_integer()
  def max_open_incidents, do: @max_open_incidents

  @doc """
  Resolves an open incident after an optional verification callback.

  `opts` accepts `:verify`, a one-argument function returning `:ok` or
  `{:error, reason}`. A failed verification leaves the incident open and
  returns the error. Re-resolving an already-resolved incident is idempotent
  (and skips verification).

  Verification runs **before** the `FOR UPDATE` transaction: a callback that
  walks the object store must not hold the incident row — or a pool
  connection — for the length of the scan. Incident kind, target, and details
  are immutable, so the decision cannot go stale; only the status transition
  needs the lock.
  """
  @spec resolve(map(), Ecto.UUID.t() | String.t(), Ecto.UUID.t() | String.t(), keyword()) ::
          {:ok, Incident.t()} | {:error, term()}
  def resolve(actor, project_id, incident_id, opts \\ []) do
    verify = Keyword.get(opts, :verify, fn _incident -> :ok end)

    with {:ok, project_id} <- uuid(project_id),
         {:ok, incident_id} <- uuid(incident_id),
         {:ok, _membership} <- authorize_decider(actor, project_id),
         {:ok, incident} <- fetch_incident(project_id, incident_id),
         :ok <- verify_target(verify, incident) do
      Repo.transaction(fn ->
        incident =
          Repo.one(
            from(i in Incident,
              where: i.id == ^incident_id and i.project_id == ^project_id,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        case incident.status do
          :resolved -> incident
          :open -> mark_resolved(incident, actor)
        end
      end)
    end
  end

  defp fetch_incident(project_id, incident_id) do
    case Repo.get_by(Incident, id: incident_id, project_id: project_id) do
      nil -> {:error, :not_found}
      incident -> {:ok, incident}
    end
  end

  defp verify_target(_verify, %Incident{status: :resolved}), do: :ok

  defp verify_target(verify, %Incident{} = incident) do
    case verify.(incident) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      _other -> {:error, :verification_failed}
    end
  end

  defp mark_resolved(incident, actor) do
    incident
    |> Ecto.Changeset.change(
      status: :resolved,
      resolved_at: DateTime.utc_now(),
      resolved_by: actor.id
    )
    |> Repo.update()
    |> case do
      {:ok, resolved} -> resolved
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  @doc "Whether an open critical incident blocks approving the proposal."
  @spec blocking_proposal?(Ecto.UUID.t() | String.t() | nil) :: boolean()
  def blocking_proposal?(nil), do: false

  def blocking_proposal?(proposal_id) do
    case UUID.cast(proposal_id) do
      {:ok, proposal_id} ->
        Repo.exists?(
          from(i in Incident,
            where: i.proposal_id == ^proposal_id and i.status == :open and i.severity == :critical
          )
        )

      :error ->
        false
    end
  end

  @doc "Whether an open critical incident isolates the node."
  @spec blocking_node?(Ecto.UUID.t() | String.t(), Ecto.UUID.t() | String.t()) :: boolean()
  def blocking_node?(project_id, node_id) do
    with {:ok, project_id} <- UUID.cast(project_id),
         {:ok, node_id} <- UUID.cast(node_id) do
      Repo.exists?(
        from(i in Incident,
          where:
            i.project_id == ^project_id and i.node_id == ^node_id and i.status == :open and
              i.severity == :critical
        )
      )
    else
      :error -> false
    end
  end

  defp existing_open_incident(changeset) do
    if duplicate_open_error?(changeset) do
      project_id = Ecto.Changeset.get_field(changeset, :project_id)
      proposal_id = Ecto.Changeset.get_field(changeset, :proposal_id)
      node_id = Ecto.Changeset.get_field(changeset, :node_id)
      kind = Ecto.Changeset.get_field(changeset, :kind)

      query =
        from(i in Incident,
          where: i.status == :open and i.kind == ^kind and i.project_id == ^project_id
        )

      query =
        if proposal_id do
          where(query, [i], i.proposal_id == ^proposal_id)
        else
          where(query, [i], is_nil(i.proposal_id))
        end

      query =
        if node_id do
          where(query, [i], i.node_id == ^node_id)
        else
          where(query, [i], is_nil(i.node_id))
        end

      Repo.one(query)
    end
  end

  defp duplicate_open_error?(changeset) do
    Enum.any?(changeset.errors, fn
      {field, {"has already been taken", _opts}}
      when field in [:proposal_id, :node_id, :project_id] ->
        true

      _error ->
        false
    end)
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
