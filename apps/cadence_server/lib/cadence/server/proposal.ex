defmodule Cadence.Server.Proposal do
  @moduledoc """
  A pending meld or promotion awaiting review (spec §6.6).

  Server-only: daemons do not consume proposals. A meld proposal carries the
  precomputed result tree and commit so reviewers can inspect the diff before
  approval; a promotion proposal points at an existing node via
  `target_node_id`. `status` is never cast from client input.

  `result_metadata` is server-owned jsonb written by `Cadence.Server.Melds`
  after the AI runs: provider, model, prompt version, conflict/op counts, and
  the intended flag. It is deliberately absent from the changeset's cast list
  so no caller can forge AI provenance.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Cadence.Shared.{Changeset, UUID}

  @primary_key {:id, Ecto.UUID, autogenerate: true}

  @kinds [:meld, :promotion]
  @statuses [:pending, :approved, :rejected]

  schema "proposals" do
    field(:token, :string)
    field(:project_id, Ecto.UUID)
    field(:proposer_id, Ecto.UUID)
    field(:kind, Ecto.Enum, values: @kinds)
    field(:parent_ids, {:array, Ecto.UUID}, default: [])
    field(:target_node_id, Ecto.UUID)
    field(:result_tree_sha, :string)
    field(:meld_commit_sha, :string)
    field(:result_metadata, :map, default: %{})
    field(:status, Ecto.Enum, values: @statuses, default: :pending)
    field(:reviewer_id, Ecto.UUID)
    field(:decided_at, :utc_datetime_usec)
    field(:created_at, :utc_datetime_usec)
  end

  @doc "The allowed proposal kinds."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc "The allowed proposal statuses."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @doc """
  Builds a proposal changeset from trusted server-side attributes.

  Requires a meld to have at least two parent IDs and both result SHAs, and a
  promotion to have a target node and no parents/result SHAs. `token`,
  `proposer_id`, `status`, `reviewer_id`, and `decided_at` are never cast.
  """
  def changeset(proposal \\ %__MODULE__{}, attrs) do
    proposal
    |> cast(attrs, [
      :project_id,
      :proposer_id,
      :kind,
      :parent_ids,
      :target_node_id,
      :result_tree_sha,
      :meld_commit_sha
    ])
    |> put_default_token()
    |> put_default_created_at()
    |> validate_required([:token, :project_id, :proposer_id, :kind, :status, :created_at])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> Changeset.validate_uuid([:project_id, :proposer_id, :target_node_id])
    |> validate_parent_uuids()
    |> validate_shape()
    |> unique_constraint(:token)
  end

  defp put_default_token(changeset) do
    if get_field(changeset, :token) do
      changeset
    else
      put_change(
        changeset,
        :token,
        :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
      )
    end
  end

  defp put_default_created_at(changeset) do
    if get_field(changeset, :created_at) do
      changeset
    else
      put_change(changeset, :created_at, DateTime.utc_now())
    end
  end

  defp validate_parent_uuids(changeset) do
    validate_change(changeset, :parent_ids, fn :parent_ids, parent_ids ->
      if is_list(parent_ids) and Enum.all?(parent_ids, &UUID.valid?/1) do
        []
      else
        [parent_ids: "must be a list of UUIDs"]
      end
    end)
  end

  defp validate_shape(changeset) do
    case get_field(changeset, :kind) do
      :meld -> validate_meld(changeset)
      :promotion -> validate_promotion(changeset)
      _ -> changeset
    end
  end

  defp validate_meld(changeset) do
    parent_ids = get_field(changeset, :parent_ids) || []

    changeset
    |> maybe_add_min_parents_error(parent_ids)
    |> validate_unique_parents(parent_ids)
    |> validate_required([:result_tree_sha, :meld_commit_sha])
    |> validate_format(:result_tree_sha, ~r/^[0-9a-f]{40}$/)
    |> validate_format(:meld_commit_sha, ~r/^[0-9a-f]{40}$/)
    |> reject_present(:target_node_id, "must be empty for a meld")
  end

  defp validate_promotion(changeset) do
    parent_ids = get_field(changeset, :parent_ids) || []

    changeset
    |> validate_required([:target_node_id])
    |> reject_present(:parent_ids, "must be empty for a promotion", parent_ids != [])
    |> reject_present(:result_tree_sha, "must be empty for a promotion")
    |> reject_present(:meld_commit_sha, "must be empty for a promotion")
  end

  defp maybe_add_min_parents_error(changeset, parent_ids) do
    if length(parent_ids) < 2 do
      add_error(changeset, :parent_ids, "must contain at least two parents")
    else
      changeset
    end
  end

  defp validate_unique_parents(changeset, parent_ids) do
    if length(Enum.uniq(parent_ids)) == length(parent_ids) do
      changeset
    else
      add_error(changeset, :parent_ids, "must not contain duplicates")
    end
  end

  defp reject_present(changeset, field, message, present? \\ nil) do
    present? = if is_nil(present?), do: not is_nil(get_field(changeset, field)), else: present?

    if present? do
      add_error(changeset, field, message)
    else
      changeset
    end
  end
end
