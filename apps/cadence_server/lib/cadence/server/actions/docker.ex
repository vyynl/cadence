defmodule Cadence.Server.Actions.Docker do
  @moduledoc """
  The narrow Docker surface the action runner needs (spec §8.3, §8.4).

  A behaviour, not a wrapper around the whole Engine API: the real client
  (`Cadence.Server.Actions.DockerEngine`) speaks to `ex_docker_api`, and tests
  inject a fake through `:actions_docker` so no test talks to a real daemon.

  Every callback returns shape-only results. Container output is only ever
  returned by `logs/2`, and the runner writes it to the artifact directory
  rather than logging it.
  """

  @typedoc """
  One volume mount for the action container.

  `:subpath` scopes a shared named volume to a run directory, so an action can
  only see its own snapshot and its own output dir (Docker Engine ≥ 26).
  """
  @type mount :: %{
          source: String.t(),
          subpath: String.t(),
          target: String.t(),
          read_only: boolean()
        }

  @typedoc "Everything needed to create one action container."
  @type container_spec :: %{
          name: String.t(),
          image: String.t(),
          command: String.t(),
          working_dir: String.t(),
          env: [String.t()],
          labels: %{optional(String.t()) => String.t()},
          mounts: [mount()],
          network: String.t(),
          memory_bytes: pos_integer(),
          nano_cpus: pos_integer(),
          pids_limit: pos_integer()
        }

  @doc "Whether the image is already present locally."
  @callback image?(image :: String.t()) :: {:ok, boolean()} | {:error, term()}

  @doc "Build `tag` from the staged snapshot context (`code_dir` + relative files)."
  @callback build_image(code_dir :: Path.t(), files :: [String.t()], tag :: String.t()) ::
              :ok | {:error, term()}

  @doc "Create a container and return its id."
  @callback create(spec :: container_spec()) :: {:ok, String.t()} | {:error, term()}

  @doc "Start a created container."
  @callback start(id :: String.t()) :: :ok | {:error, term()}

  @doc "Wait for exit and return the exit code, or `{:error, :timeout}`."
  @callback wait(id :: String.t()) :: {:ok, integer()} | {:error, :timeout | term()}

  @doc "Read combined stdout/stderr, truncated to `max_bytes`."
  @callback logs(id :: String.t(), max_bytes :: non_neg_integer()) ::
              {:ok, binary()} | {:error, term()}

  @doc "Stop a running container (used on timeout)."
  @callback stop(id :: String.t()) :: :ok | {:error, term()}

  @doc "Force-remove a container and its anonymous volumes."
  @callback remove(id :: String.t()) :: :ok | {:error, term()}

  @doc "The configured client implementation (fake in tests)."
  @spec impl() :: module()
  def impl do
    Application.get_env(:cadence_server, :actions_docker, Cadence.Server.Actions.DockerEngine)
  end
end
