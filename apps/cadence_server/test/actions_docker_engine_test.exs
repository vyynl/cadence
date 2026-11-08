defmodule Cadence.Server.Actions.DockerEngineTest do
  # Pure request-building and response-mapping tests. No daemon is contacted;
  # this is the layer the injected fake client cannot cover.
  use ExUnit.Case, async: true

  alias Cadence.Server.Actions.DockerEngine

  alias DockerEngineAPI.Model.{
    ContainerCreateRequest,
    ContainerCreateResponse,
    ContainerWaitResponse,
    ErrorResponse,
    HostConfig,
    HostConfigAllOfLogConfig,
    ImageSummary,
    Mount,
    MountVolumeOptions
  }

  @spec_map %{
    name: "cadence-run-run-1",
    image: "cadence-action-demo-abcdef123456",
    command: "python actions/run.py",
    working_dir: "/workspace",
    env: ["CADENCE_RUN_ID=run-1"],
    labels: %{"cadence.run" => "run-1"},
    mounts: [
      %{source: "cadence_actions", subpath: "run-1/code", target: "/workspace", read_only: true},
      %{source: "cadence_actions", subpath: "run-1/out", target: "/out", read_only: false}
    ],
    network: "none",
    memory_bytes: 536_870_912,
    nano_cpus: 1_000_000_000,
    pids_limit: 256
  }

  describe "create_request/1" do
    test "overrides the image entrypoint so the command is /bin/sh -c" do
      request = DockerEngine.create_request(@spec_map)

      assert %ContainerCreateRequest{
               Entrypoint: ["/bin/sh", "-c"],
               Cmd: ["python actions/run.py"],
               Image: image,
               WorkingDir: "/workspace",
               Tty: true,
               Labels: %{"cadence.run" => "run-1"},
               Env: ["CADENCE_RUN_ID=run-1"]
             } = request

      assert image == @spec_map.image
    end

    test "mounts only the run's code and out subpaths" do
      %ContainerCreateRequest{HostConfig: %HostConfig{Mounts: mounts}} =
        DockerEngine.create_request(@spec_map)

      assert [
               %Mount{
                 Type: "volume",
                 Source: "cadence_actions",
                 Target: "/workspace",
                 ReadOnly: true,
                 VolumeOptions: %MountVolumeOptions{Subpath: "run-1/code"}
               },
               %Mount{
                 Type: "volume",
                 Source: "cadence_actions",
                 Target: "/out",
                 ReadOnly: false,
                 VolumeOptions: %MountVolumeOptions{Subpath: "run-1/out"}
               }
             ] = mounts
    end

    test "host config carries the isolation baseline" do
      assert %HostConfig{
               NetworkMode: "none",
               Memory: 536_870_912,
               MemorySwap: 536_870_912,
               NanoCpus: 1_000_000_000,
               PidsLimit: 256,
               ReadonlyRootfs: true,
               CapDrop: ["ALL"],
               SecurityOpt: ["no-new-privileges"],
               AutoRemove: false,
               Tmpfs: %{"/tmp" => "rw,noexec,nosuid,size=64m"},
               LogConfig: %HostConfigAllOfLogConfig{
                 Type: "json-file",
                 Config: %{"max-size" => "1m", "max-file" => "1"}
               }
             } = DockerEngine.host_config(@spec_map)
    end
  end

  describe "response mapping" do
    test "start_result never reports an HTTP error as started" do
      assert DockerEngine.start_result({:ok, %Tesla.Env{status: 204}}) == :ok
      assert DockerEngine.start_result({:ok, %Tesla.Env{status: 304}}) == :ok

      assert DockerEngine.start_result({:ok, %ErrorResponse{}}) == {:error, :start_failed}
      assert DockerEngine.start_result({:error, :econnrefused}) == {:error, :start_failed}
    end

    test "create_result maps an id and every error shape" do
      assert DockerEngine.create_result({:ok, %ContainerCreateResponse{Id: "abc"}}) ==
               {:ok, "abc"}

      assert DockerEngine.create_result({:ok, %ErrorResponse{}}) == {:error, :create_failed}

      assert DockerEngine.create_result({:error, :econnrefused}) ==
               {:error, :docker_unavailable}
    end

    test "wait_result maps exit codes, engine errors, and timeouts" do
      assert DockerEngine.wait_result({:ok, %ContainerWaitResponse{StatusCode: 0}}) == {:ok, 0}
      assert DockerEngine.wait_result({:ok, %ContainerWaitResponse{StatusCode: 2}}) == {:ok, 2}

      assert DockerEngine.wait_result(
               {:ok,
                %ContainerWaitResponse{
                  StatusCode: 0,
                  Error: %DockerEngineAPI.Model.ContainerWaitExitError{Message: "boom"}
                }}
             ) == {:error, :wait_failed}

      assert DockerEngine.wait_result({:ok, %ErrorResponse{}}) == {:error, :wait_failed}
      assert DockerEngine.wait_result({:error, :timeout}) == {:error, :timeout}
      assert DockerEngine.wait_result({:error, :closed}) == {:error, :wait_failed}
    end

    test "build_result detects streamed error records" do
      assert DockerEngine.build_result(~s({"stream":"Step 1/2"}\n)) == :ok
      assert DockerEngine.build_result(~s({"error":"boom"}\n)) == {:error, :build_failed}

      assert DockerEngine.build_result(~s({"errorDetail":{"message":"boom"}}\n)) ==
               {:error, :build_failed}

      assert DockerEngine.build_result(nil) == :ok
    end
  end

  describe "trim_log/2" do
    test "passes short logs through unchanged" do
      assert DockerEngine.trim_log("hello\n", 1_024) == "hello\n"
    end

    test "keeps the tail and stays valid UTF-8" do
      body = String.duplicate("é", 100)
      trimmed = DockerEngine.trim_log(body, 21)

      assert String.starts_with?(trimmed, "[cadence] log truncated")
      assert String.valid?(trimmed)
      assert byte_size(trimmed) <= 21 + 64
    end

    test "a zero cap still returns a marker" do
      assert DockerEngine.trim_log("anything", 0) =~ "[cadence] log truncated"
    end
  end

  describe "image_entries/1" do
    test "maps one entry per repository tag" do
      summary = %ImageSummary{
        Id: "sha256:abc",
        RepoTags: ["cadence-action-demo-aaaaaaaaaaaa", "cadence-action-demo-bbbbbbbbbbbb"],
        Created: 1_700_000_000
      }

      assert DockerEngine.image_entries(summary) == [
               %{
                 tags: ["cadence-action-demo-aaaaaaaaaaaa"],
                 created_at: 1_700_000_000,
                 id: "sha256:abc"
               },
               %{
                 tags: ["cadence-action-demo-bbbbbbbbbbbb"],
                 created_at: 1_700_000_000,
                 id: "sha256:abc"
               }
             ]
    end

    test "an untagged image and a non-summary decode contribute nothing" do
      assert DockerEngine.image_entries(%ImageSummary{RepoTags: nil, Created: 1, Id: "id"}) == []
      assert DockerEngine.image_entries(%ErrorResponse{}) == []
    end
  end
end
