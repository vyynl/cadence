defmodule Cadence.Server.Incident do
  @moduledoc """
  A critical finding that isolates risky or invalid content pending review
  (spec §6.7).

  Server-only. Incidents reference a proposal, a node, both, or neither.
  Project-scoped incidents (no proposal/node) are used for meld failures, where
  no proposal exists yet (spec §6.7). `details` stores scanner metadata only
  (pattern names, counts, redacted reasons); secret values and file contents
  must never be written here.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Cadence.Server.PublicContent
  alias Cadence.Shared.Changeset, as: SharedChangeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}

  @kinds [
    :secret_detected,
    :scan_incomplete,
    :meld_failed,
    :agent_output_invalid,
    :missing_objects
  ]

  @severities [:critical, :high]
  @statuses [:open, :resolved]

  schema "incidents" do
    field(:project_id, Ecto.UUID)
    field(:proposal_id, Ecto.UUID)
    field(:node_id, Ecto.UUID)
    field(:kind, Ecto.Enum, values: @kinds)
    field(:severity, Ecto.Enum, values: @severities, default: :critical)
    field(:status, Ecto.Enum, values: @statuses, default: :open)
    field(:title, :string)
    field(:details, :map, default: %{})
    field(:created_at, :utc_datetime_usec)
    field(:resolved_at, :utc_datetime_usec)
    field(:resolved_by, Ecto.UUID)
  end

  @doc "The allowed incident kinds."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc "The allowed incident severities."
  @spec severities() :: [atom()]
  def severities, do: @severities

  @doc "The allowed incident statuses."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @doc """
  Builds an incident changeset.

  Requires a project, kind, severity, title, and details. A proposal or node
  reference is optional: a meld failure can alert the project without a
  proposal. Rejects `details` that contain secret-looking strings. `status`,
  `resolved_at`, and `resolved_by` are server-owned.
  """
  def changeset(incident \\ %__MODULE__{}, attrs) do
    incident
    |> cast(attrs, [:project_id, :proposal_id, :node_id, :kind, :severity, :title, :details])
    |> put_default_created_at()
    |> validate_required([:project_id, :kind, :severity, :title, :details, :created_at])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:severity, @severities)
    |> validate_inclusion(:status, @statuses)
    |> SharedChangeset.validate_uuid([:project_id, :proposal_id, :node_id])
    |> validate_details()
    |> unique_constraint([:proposal_id, :kind], name: :incidents_open_proposal_kind_index)
    |> unique_constraint([:node_id, :kind], name: :incidents_open_node_kind_index)
    |> unique_constraint([:project_id, :kind], name: :incidents_open_project_kind_index)
  end

  defp put_default_created_at(changeset) do
    if get_field(changeset, :created_at) do
      changeset
    else
      put_change(changeset, :created_at, DateTime.utc_now())
    end
  end

  defp validate_details(changeset) do
    case get_field(changeset, :details) do
      details when is_map(details) ->
        if contains_sensitive?(details) do
          add_error(changeset, :details, "must not contain secret-looking values")
        else
          changeset
        end

      _details ->
        add_error(changeset, :details, "must be a map")
    end
  end

  defp contains_sensitive?(value) when is_binary(value), do: PublicContent.sensitive?(value)

  defp contains_sensitive?(value) when is_list(value),
    do: Enum.any?(value, &contains_sensitive?/1)

  defp contains_sensitive?(value) when is_map(value),
    do: value |> Map.values() |> Enum.any?(&contains_sensitive?/1)

  defp contains_sensitive?(_value), do: false
end
