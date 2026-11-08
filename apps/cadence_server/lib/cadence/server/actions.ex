defmodule Cadence.Server.Actions do
  @moduledoc """
  Read-only access to a project's Docker actions (spec §8).

  Phase 6a loads and validates a node's `actions/manifest.json`; 6b executes an
  action against the same snapshot through `Cadence.Server.Actions.Runs`.
  Reading is snapshot-addressed: the manifest comes from the selected node's Git
  tree, never a server working copy.

  Callers own snapshot quarantine: `ProjectLive` hides the panel for a
  quarantined snapshot, and `Runs.prepare/4` re-checks the incident before
  writing a run row (staging re-scans the content). The manifest file itself is
  still ordinary repository content and is not confidential.
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
  Maximum concurrent `:running` action runs per project (spec §8.3).

  `0` disables the cap (unlimited, matching the pre-queue behavior). A negative or
  non-integer value falls back to the default of 1, so a bad environment value
  can never remove the bound by accident.
  """
  @spec max_concurrent_runs() :: non_neg_integer()
  def max_concurrent_runs do
    case Application.get_env(:cadence_server, :actions_max_concurrent_runs, 1) do
      value when is_integer(value) and value >= 0 -> value
      _other -> 1
    end
  end

  @doc """
  Whether the boot pass dispatches queued runs (spec §8.3).

  Disabled in tests: a boot process must not query the sandboxed Repo.
  """
  @spec dispatch_on_boot?() :: boolean()
  def dispatch_on_boot?,
    do: Application.get_env(:cadence_server, :actions_dispatch_on_boot, true) == true

  @doc "Root directory for action logs and collected artifacts (`CAD_ARTIFACT_PATH`)."
  @spec artifact_path() :: String.t()
  def artifact_path, do: config_str(:artifact_path, "/data/artifacts")

  @doc """
  Age in days after which a terminal run's logs/artifacts are removed
  (`CAD_ACTIONS_ARTIFACT_RETENTION_DAYS`; `0` disables the sweep).
  """
  @spec artifact_retention_days() :: non_neg_integer()
  def artifact_retention_days, do: non_negative_int(:actions_artifact_retention_days, 30)

  @doc """
  Backstop interval for the retention sweep
  (`CAD_ACTIONS_RETENTION_INTERVAL_MS`; `0` disables the periodic pass).
  """
  @spec retention_interval_ms() :: non_neg_integer()
  def retention_interval_ms, do: non_negative_int(:actions_retention_interval_ms, 21_600_000)

  @doc """
  Maximum runs one retention pass examines
  (`CAD_ACTIONS_RETENTION_BATCH`, default 500). A value below 1 falls back to
  the default so a typo cannot make the sweep a permanent no-op.
  """
  @spec retention_batch() :: pos_integer()
  def retention_batch do
    case non_negative_int(:actions_retention_batch, 500) do
      0 -> 500
      value -> value
    end
  end

  @doc """
  How many `cadence-action-*` images to keep per project
  (`CAD_ACTIONS_IMAGE_RETENTION_PER_PROJECT`; `0` disables image pruning).
  """
  @spec image_retention_per_project() :: non_neg_integer()
  def image_retention_per_project,
    do: non_negative_int(:actions_image_retention_per_project, 5)

  @doc """
  Container limits and network mode for one action run (spec §8.3).

  Shared by the runner (container spec) and the Docker engine (build limits), so
  both use the same numbers and a positive floor.
  """
  @spec limits() :: %{
          network: String.t(),
          memory_bytes: pos_integer(),
          nano_cpus: pos_integer(),
          pids_limit: pos_integer()
        }
  def limits do
    cpus = max(config_int(:actions_max_cpus, 1), 1)

    %{
      network: config_str(:actions_network, "none"),
      memory_bytes: max(config_int(:actions_memory_mb, 512), 1) * 1_048_576,
      nano_cpus: cpus * 1_000_000_000,
      pids_limit: max(config_int(:actions_pids_limit, 256), 1)
    }
  end

  @doc """
  Limits for an image build (`Dockerfile` `RUN` steps), separated from the
  run-container limits because the build gets its own network mode
  (`CAD_ACTIONS_BUILD_NETWORK`, default `none`) and a CPU quota instead of
  `NanoCpus` (spec §8.3).
  """
  @spec build_limits() :: %{
          network: String.t(),
          memory_bytes: pos_integer(),
          cpu_quota: pos_integer()
        }
  def build_limits do
    %{
      network: config_str(:actions_build_network, "none"),
      memory_bytes: limits().memory_bytes,
      cpu_quota: max(config_int(:actions_max_cpus, 1), 1) * 100_000
    }
  end

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

  defp non_negative_int(key, default) do
    case Application.get_env(:cadence_server, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _other -> default
    end
  end

  defp config_str(key, default) do
    case Application.get_env(:cadence_server, key, default) do
      value when is_binary(value) and value != "" -> value
      _other -> default
    end
  end
end
