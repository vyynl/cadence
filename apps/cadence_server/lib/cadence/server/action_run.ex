defmodule Cadence.Server.ActionRun do
  @moduledoc """
  One Docker action execution against an immutable node snapshot (spec §8).

  Server-only. The row is inserted as `:queued` before any container exists, so
  a crash or restart leaves a durable record instead of a lost request. Status
  transitions are owned by `Cadence.Server.Actions.Runs`: `status` is never cast
  from client input, and a terminal status always carries `finished_at`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Cadence.Shared.Changeset, as: SharedChangeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}

  @statuses [:queued, :running, :succeeded, :failed, :timed_out, :interrupted]
  @terminal_statuses [:succeeded, :failed, :timed_out, :interrupted]
  @name_format ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/
  @max_command_bytes 512

  @transition_fields [
    :status,
    :exit_code,
    :image,
    :container_id,
    :error_reason,
    :log_path,
    :artifact_path,
    :artifact_error,
    :started_at,
    :finished_at,
    :updated_at
  ]

  schema "action_runs" do
    field(:project_id, Ecto.UUID)
    field(:node_id, Ecto.UUID)
    field(:user_id, Ecto.UUID)
    field(:action_name, :string)
    field(:command, :string)
    field(:status, Ecto.Enum, values: @statuses, default: :queued)
    field(:exit_code, :integer)
    field(:image, :string)
    field(:container_id, :string)
    field(:error_reason, :string)
    field(:log_path, :string)
    field(:artifact_path, :string)
    field(:artifact_error, :string)
    field(:created_at, :utc_datetime_usec)
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  @doc "The allowed run statuses, in lifecycle order."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @doc "Statuses after which no further transition is allowed."
  @spec terminal_statuses() :: [atom()]
  def terminal_statuses, do: @terminal_statuses

  @doc "Whether `status` is terminal."
  @spec terminal?(atom() | nil) :: boolean()
  def terminal?(status), do: status in @terminal_statuses

  @doc """
  Builds the creation changeset from trusted server-side attributes.

  Requires the project/node/user ids, the manifest action name, and the command
  snapshot. Status starts `:queued`; only `Cadence.Server.Actions.Runs` may move
  it.
  """
  def changeset(run \\ %__MODULE__{}, attrs) do
    now = DateTime.utc_now()

    run
    |> cast(attrs, [:id, :project_id, :node_id, :user_id, :action_name, :command])
    |> put_change(:status, :queued)
    |> put_change(:created_at, now)
    |> put_change(:updated_at, now)
    |> validate_required([
      :project_id,
      :node_id,
      :user_id,
      :action_name,
      :command,
      :status,
      :created_at
    ])
    |> SharedChangeset.validate_uuid([:project_id, :node_id, :user_id])
    |> validate_format(:action_name, @name_format)
    |> validate_length(:command, min: 1, max: @max_command_bytes)
  end

  @doc """
  The fields a status transition may set.

  Callers must build transitions with this list so a run can never be rewritten
  with new identity, command, or project data.
  """
  @spec transition_fields() :: [atom()]
  def transition_fields, do: @transition_fields
end
