defmodule Cadence.Server.Actions do
  @moduledoc """
  Read-only access to a project's Docker actions (spec §8).

  Phase 6a loads and validates a node's `actions/manifest.json`; execution in
  per-project containers lands in 6b. Reading is snapshot-addressed: the
  manifest comes from the selected node's Git tree, never a server working
  copy.

  Callers own snapshot quarantine: `ProjectLive` hides the panel for a
  quarantined snapshot, and 6b must re-check before running anything. The
  manifest file itself is still ordinary repository content and is not
  confidential.
  """

  alias Cadence.Server.Actions.Manifest
  alias Cadence.Server.{Authorization, ProjectGit}
  alias Cadence.Shared.{GitStore, Membership, Node, Project}

  @manifest_path "actions/manifest.json"

  @doc "Whether the action layer is enabled for this deployment."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:cadence_server, :actions_enabled, true)

  @doc "Repository path of the action manifest."
  @spec manifest_path() :: String.t()
  def manifest_path, do: @manifest_path

  @doc """
  Load and validate the action manifest for a node.

  Members may read the list; execution is a separate, manager-only decision
  (6b). Returns `{:error, :forbidden}` before touching the store for
  non-members or a membership from another project, `{:error, :disabled}` when
  the layer is off, and `{:error, :not_found}` when the snapshot has no
  manifest.
  """
  @spec list(Project.t() | nil, Node.t() | nil, Membership.t() | nil) ::
          {:ok, Manifest.t()} | {:error, atom()}
  def list(project, node, membership) do
    with :ok <- check_enabled(),
         :ok <- check_member(project, membership),
         :ok <- check_node(project, node) do
      read_manifest(project, node)
    end
  end

  defp check_enabled do
    if enabled?(), do: :ok, else: {:error, :disabled}
  end

  # The membership must belong to this project: a valid role from project A
  # must not read project B's manifest.
  defp check_member(%Project{id: project_id}, %Membership{project_id: project_id} = membership) do
    if Authorization.can_view?(membership), do: :ok, else: {:error, :forbidden}
  end

  defp check_member(_project, _membership), do: {:error, :forbidden}

  defp check_node(%Project{id: project_id}, %Node{project_id: project_id}), do: :ok
  defp check_node(_project, _node), do: {:error, :not_found}

  defp read_manifest(%Project{id: project_id}, %Node{git_commit_sha: sha}) do
    max_bytes = config_int(:actions_max_manifest_bytes, Manifest.default_max_bytes())
    repo = ProjectGit.open(project_id)

    case GitStore.read_path(repo, sha, @manifest_path, max_bytes: max_bytes) do
      {:ok, json} ->
        Manifest.parse(json,
          max_bytes: max_bytes,
          max_actions: config_int(:actions_max_actions, Manifest.default_max_actions())
        )

      {:error, reason} when reason in [:not_found, :not_a_file] ->
        {:error, :not_found}

      {:error, :too_large} ->
        {:error, :too_large}

      {:error, _reason} ->
        {:error, :invalid_manifest}
    end
  rescue
    # A structurally corrupt store can raise inside tree decoding; the public
    # project page must treat it as an unreadable manifest, never a 500.
    _error -> {:error, :invalid_manifest}
  end

  defp config_int(key, default), do: Application.get_env(:cadence_server, key, default)
end
