defmodule Cadence.Server.Actions.DockerEngine do
  @moduledoc """
  `ex_docker_api` implementation of `Cadence.Server.Actions.Docker` (spec §8.3).

  Talks to the Docker Engine through `CAD_DOCKER_SOCKET`, which must be the
  socket proxy's HTTP endpoint (never a raw host socket in a public deployment,
  §8.4). `CAD_DOCKER_API_VERSION` defaults to `v1.45`: that is the oldest
  version with `volume-subpath` support, and it keeps Docker 26–29 working.
  There is no version negotiation; point the setting at the daemon's maximum if
  a deployment needs a newer API.

  The client is built per call with a timeout sized to the operation: a build
  pulls base layers and gets a longer budget than a container wait. Every
  failure is normalized to a shape-only atom; container output is never logged
  here.

  Request building and response mapping are pure functions (`create_request/1`
  and the `*_result/1` helpers) so they can be unit-tested without a daemon.
  """

  @behaviour Cadence.Server.Actions.Docker

  alias Cadence.Server.Actions
  alias Cadence.Server.Actions.Staging
  alias DockerEngineAPI.Api.{Container, Image}
  alias DockerEngineAPI.Connection

  alias DockerEngineAPI.Model.{
    ContainerCreateRequest,
    ContainerCreateResponse,
    ContainerWaitResponse,
    ErrorResponse,
    HostConfig,
    HostConfigAllOfLogConfig,
    ImageInspect,
    Mount,
    MountVolumeOptions
  }

  @timeout_margin_ms 10_000
  @default_api_version "v1.45"

  @impl true
  def image?(image) do
    case Image.image_inspect(client(:run), image) do
      {:ok, %ImageInspect{}} -> {:ok, true}
      # 404 and an engine error share one model in this client; treating both as
      # "absent" only costs an extra build/attempt, which then fails loudly.
      {:ok, %ErrorResponse{}} -> {:ok, false}
      {:ok, _other} -> {:ok, false}
      {:error, _reason} -> {:error, :docker_unavailable}
    end
  end

  @impl true
  def build_image(code_dir, files, tag) do
    with {:ok, context} <- Staging.build_context(code_dir, files) do
      limits = Actions.build_limits()

      opts = [
        body: context,
        t: tag,
        dockerfile: "Dockerfile",
        rm: true,
        # `q` keeps the JSON-lines build response small; errors are still
        # emitted as {"error": ...}/{"errorDetail": ...} records.
        q: true,
        networkmode: limits.network,
        memory: limits.memory_bytes,
        memswap: limits.memory_bytes,
        cpuperiod: 100_000,
        cpuquota: limits.cpu_quota,
        "Content-type": "application/x-tar"
      ]

      case Image.image_build(client(:build), opts) do
        {:ok, %Tesla.Env{body: body}} -> build_result(body)
        {:ok, %ErrorResponse{}} -> {:error, :build_failed}
        {:error, _reason} -> {:error, :build_failed}
      end
    end
  end

  @impl true
  def create(spec) do
    spec
    |> create_request()
    |> then(&Container.container_create(client(:run), &1, name: spec.name))
    |> create_result()
  end

  @impl true
  def start(id) do
    Container.container_start(client(:run), id) |> start_result()
  end

  @impl true
  def wait(id) do
    Container.container_wait(client(:run), id) |> wait_result()
  end

  @impl true
  def logs(id, max_bytes) do
    opts = [stdout: true, stderr: true, timestamps: false]

    case Container.container_logs(client(:run), id, opts) do
      {:ok, %Tesla.Env{body: body}} when is_binary(body) -> {:ok, trim_log(body, max_bytes)}
      {:ok, body} when is_binary(body) -> {:ok, trim_log(body, max_bytes)}
      {:ok, %ErrorResponse{}} -> {:error, :logs_failed}
      {:error, _reason} -> {:error, :logs_failed}
    end
  end

  @impl true
  def stop(id) do
    case Container.container_stop(client(:run), id, t: 5) do
      {:ok, %ErrorResponse{}} -> {:error, :stop_failed}
      {:ok, _response} -> :ok
      {:error, _reason} -> {:error, :stop_failed}
    end
  end

  @impl true
  def remove(id) do
    # Use a raw request so the HTTP status survives: 404 means "already gone"
    # (success), while 409/500 are real failures that recovery must retry.
    path = "/containers/#{id}?force=1&v=1"

    case Tesla.delete(client(:run), path) do
      {:ok, %Tesla.Env{status: status}} when status in [204, 404] -> :ok
      {:ok, %Tesla.Env{status: _status}} -> {:error, :remove_failed}
      {:error, _reason} -> {:error, :remove_failed}
    end
  end

  ## Request building (pure; unit-tested)

  @doc false
  def create_request(spec) do
    %ContainerCreateRequest{
      # Setting Entrypoint overrides the image's own entrypoint, so the
      # documented `/bin/sh -c <command>` contract holds for project.docker_image
      # as well as for built images.
      Entrypoint: ["/bin/sh", "-c"],
      Cmd: [spec.command],
      Image: spec.image,
      WorkingDir: spec.working_dir,
      Tty: true,
      AttachStdout: true,
      AttachStderr: true,
      Env: spec.env,
      Labels: spec.labels,
      HostConfig: host_config(spec)
    }
  end

  @doc false
  def host_config(spec) do
    %HostConfig{
      NetworkMode: spec.network,
      Memory: spec.memory_bytes,
      # Without this Docker defaults the swap budget to 2x memory.
      MemorySwap: spec.memory_bytes,
      NanoCpus: spec.nano_cpus,
      PidsLimit: spec.pids_limit,
      ReadonlyRootfs: true,
      SecurityOpt: ["no-new-privileges"],
      CapDrop: ["ALL"],
      AutoRemove: false,
      # A read-only rootfs has no writable /tmp; give tools a small, noexec one.
      Tmpfs: %{"/tmp" => "rw,noexec,nosuid,size=64m"},
      LogConfig: %HostConfigAllOfLogConfig{
        Type: "json-file",
        Config: %{"max-size" => "1m", "max-file" => "1"}
      },
      Mounts: Enum.map(spec.mounts, &mount/1)
    }
  end

  defp mount(%{source: source, subpath: subpath, target: target, read_only: read_only}) do
    %Mount{
      Type: "volume",
      Source: source,
      Target: target,
      ReadOnly: read_only,
      VolumeOptions: %MountVolumeOptions{Subpath: subpath}
    }
  end

  ## Response mapping (pure; unit-tested)

  @doc false
  def create_result({:ok, %ContainerCreateResponse{Id: id}}) when is_binary(id) do
    {:ok, id}
  end

  def create_result({:ok, %ErrorResponse{}}), do: {:error, :create_failed}
  def create_result({:ok, _other}), do: {:error, :create_failed}
  def create_result({:error, _reason}), do: {:error, :docker_unavailable}

  # Only an Env means the 204/304 success mapping; an ErrorResponse is a
  # 404/500 and must never be treated as a started container.
  @doc false
  def start_result({:ok, %Tesla.Env{}}), do: :ok
  def start_result({:ok, %ErrorResponse{}}), do: {:error, :start_failed}
  def start_result({:error, _reason}), do: {:error, :start_failed}

  @doc false
  def wait_result({:ok, %ContainerWaitResponse{Error: error}}) when not is_nil(error) do
    {:error, :wait_failed}
  end

  def wait_result({:ok, %ContainerWaitResponse{StatusCode: code}}) when is_integer(code) do
    {:ok, code}
  end

  def wait_result({:ok, %ContainerWaitResponse{}}), do: {:error, :wait_failed}
  def wait_result({:ok, %ErrorResponse{}}), do: {:error, :wait_failed}
  def wait_result({:error, :timeout}), do: {:error, :timeout}
  def wait_result({:error, _reason}), do: {:error, :wait_failed}

  @doc false
  def build_result(body) when is_binary(body) do
    if body
       |> String.split("\n", trim: true)
       |> Enum.any?(&build_line_error?/1) do
      {:error, :build_failed}
    else
      :ok
    end
  end

  def build_result(_body), do: :ok

  # Keep the tail: errors are at the end of a run. The marker is inside the cap
  # so a truncated log is self-describing.
  @doc false
  def trim_log(body, max_bytes) when byte_size(body) <= max_bytes, do: body

  def trim_log(_body, max_bytes) when max_bytes <= 0 do
    "[cadence] log truncated: cap is 0 bytes\n"
  end

  def trim_log(body, max_bytes) do
    marker = "[cadence] log truncated; showing the last #{max_bytes} bytes\n"
    keep = max(max_bytes - byte_size(marker), 0)
    tail = binary_part(body, byte_size(body) - keep, keep)
    marker <> valid_tail(tail)
  end

  ## Internals

  defp build_line_error?(line) do
    case JSON.decode(line) do
      {:ok, %{"error" => _message}} -> true
      {:ok, %{"errorDetail" => _detail}} -> true
      _other -> false
    end
  end

  defp valid_tail(tail) do
    cond do
      tail == "" -> ""
      String.valid?(tail) -> tail
      byte_size(tail) <= 1 -> ""
      true -> drop_partial_leading(tail)
    end
  end

  # A tail cut mid-codepoint starts with up to three continuation bytes; drop
  # them so the stored log is valid UTF-8.
  defp drop_partial_leading(tail) do
    if byte_size(tail) <= 4 do
      ""
    else
      candidate = binary_part(tail, 1, byte_size(tail) - 1)

      if String.valid?(candidate), do: candidate, else: drop_partial_leading(candidate)
    end
  end

  defp client(purpose) do
    Connection.new(base_url: base_url(), timeout: timeout(purpose) + @timeout_margin_ms)
  end

  defp base_url do
    socket =
      Application.get_env(:cadence_server, :docker_socket, "http://localhost:2375")
      |> to_string()
      |> String.trim_trailing("/")

    socket <> "/" <> api_version()
  end

  defp api_version do
    version =
      Application.get_env(:cadence_server, :docker_api_version, @default_api_version)
      |> to_string()
      |> String.trim("/")

    if String.starts_with?(version, "v"), do: version, else: "v" <> version
  end

  defp timeout(:build), do: config_int(:actions_build_timeout_ms, 300_000)
  defp timeout(:run), do: config_int(:actions_timeout_ms, 120_000)

  defp config_int(key, default) do
    case Application.get_env(:cadence_server, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _other -> default
    end
  end
end
