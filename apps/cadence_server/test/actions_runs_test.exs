defmodule Cadence.Server.Actions.RunsTest do
  # Shared sandbox: start/4 runs execute/1 in a Task, which needs the owner's
  # connection. async: false keeps the shared connection single-test.
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Cadence.Server.{ActionRun, Incidents, Repo}
  alias Cadence.Server.Actions.Runs
  alias Cadence.Server.Accounts.User
  alias Cadence.Server.FakeDocker
  alias Cadence.ServerFixtures, as: F

  @manifest Jason.encode!(%{
              "actions" => [
                %{
                  "name" => "run_analysis",
                  "command" => "python actions/run.py",
                  "description" => "Run the analysis"
                }
              ]
            })
  @dockerfile "FROM alpine:3.20\nCMD [\"true\"]\n"

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    Application.put_env(:cadence_server, :actions_docker, FakeDocker)
    FakeDocker.setup()

    previous = previous_config()
    on_exit(fn -> restore_config(previous) end)

    volume_path = Application.fetch_env!(:cadence_server, :actions_volume_path)
    artifact_path = Application.fetch_env!(:cadence_server, :artifact_path)
    File.rm_rf!(volume_path)
    File.rm_rf!(artifact_path)

    project = F.project(Ecto.UUID.generate(), %{slug: "actions-run"})
    owner = seed_user("actions-run-owner@example.com")
    viewer = seed_user("actions-run-viewer@example.com")
    F.membership(project, owner.id, :owner)
    F.membership(project, viewer.id, :viewer)

    node = F.node_with_snapshot(project, snapshot_files())

    %{
      project: project,
      owner: owner,
      viewer: viewer,
      node: node,
      volume_path: volume_path,
      artifact_path: artifact_path
    }
  end

  describe "execute/1" do
    test "a successful run records the image, log, and cleanup", %{
      project: project,
      owner: owner,
      node: node,
      volume_path: volume_path
    } do
      assert {:ok, run} = prepare(owner, project, node)
      assert run.status == :queued
      assert run.command == "python actions/run.py"

      assert {:ok, finished} = Runs.execute(run)
      assert finished.status == :succeeded
      assert finished.exit_code == 0
      assert finished.image == tag(project, node)
      assert finished.container_id == "container-1"
      assert finished.log_path == Path.join(run.id, "output.log")
      assert finished.artifact_path == nil
      assert {:ok, "action output\n"} = Runs.log(finished)

      assert [[spec]] = FakeDocker.calls(:create)
      assert spec.image == tag(project, node)
      assert spec.command == "python actions/run.py"
      assert spec.working_dir == "/workspace"
      assert spec.network == "none"
      assert spec.memory_bytes == 512 * 1_024 * 1_024
      assert spec.nano_cpus == 1_000_000_000
      assert spec.pids_limit == 256
      assert spec.name == "cadence-run-#{run.id}"

      assert [
               %{subpath: code_subpath, target: "/workspace", read_only: true},
               %{subpath: out_subpath, target: "/out", read_only: false}
             ] = spec.mounts

      assert code_subpath == Path.join(run.id, "code")
      assert out_subpath == Path.join(run.id, "out")

      assert "CADENCE_RUN_ID=#{run.id}" in spec.env
      assert spec.labels["cadence.project"] == project.id
      assert spec.labels["cadence.node"] == node.id

      # No build: the cached image is already present.
      assert FakeDocker.calls(:image?) == [[tag(project, node)]]
      assert FakeDocker.calls(:build_image) == []
      assert FakeDocker.calls(:start) == [["container-1"]]
      assert FakeDocker.calls(:remove) == [["container-1"]]

      # A confirmed removal clears the id; only failed removals remain sweepable.
      assert Repo.get!(ActionRun, run.id).container_id == nil

      refute File.exists?(Path.join(volume_path, run.id))
    end

    test "artifacts written to /out are collected under the artifact path", %{
      project: project,
      owner: owner,
      node: node,
      volume_path: volume_path,
      artifact_path: artifact_path
    } do
      assert {:ok, run} = prepare(owner, project, node)
      out_dir = Path.join([volume_path, run.id, "out"])
      File.mkdir_p!(out_dir)

      FakeDocker.script(%{
        on_wait: fn ->
          File.mkdir_p!(Path.join(out_dir, "nested"))
          File.write!(Path.join(out_dir, "report.txt"), "ok\n")
          File.write!(Path.join([out_dir, "nested", "data.csv"]), "a,b\n")
        end
      })

      assert {:ok, finished} = Runs.execute(run)
      assert finished.status == :succeeded
      assert finished.artifact_path == Path.join(run.id, "artifacts")
      assert finished.artifact_error == nil

      assert Runs.artifacts(finished) == [
               %{path: "nested/data.csv", size: 4},
               %{path: "report.txt", size: 3}
             ]

      assert File.read!(Path.join([artifact_path, run.id, "artifacts", "report.txt"])) == "ok\n"
    end

    test "a wait failure that cannot stop the container skips collection", %{
      project: project,
      owner: owner,
      node: node
    } do
      FakeDocker.script(%{wait: {:error, :wait_failed}, stop: {:error, :boom}})

      assert {:ok, run} = prepare(owner, project, node)
      assert {:ok, finished} = Runs.execute(run)

      assert finished.status == :failed
      assert finished.error_reason == "run_failed"
      assert finished.artifact_error == "collect_skipped"
      assert finished.log_path == nil
      assert FakeDocker.calls(:logs) == []
      # Force-removal is still attempted so the container cannot linger.
      assert FakeDocker.calls(:remove) == [["container-1"]]
    end

    test "a non-zero exit is a failed run with the code and artifacts", %{
      project: project,
      owner: owner,
      node: node,
      volume_path: volume_path
    } do
      assert {:ok, run} = prepare(owner, project, node)
      out_dir = Path.join([volume_path, run.id, "out"])
      File.mkdir_p!(out_dir)

      FakeDocker.script(%{
        wait: {:ok, 2},
        on_wait: fn -> File.write!(Path.join(out_dir, "partial.txt"), "x") end
      })

      assert {:ok, finished} = Runs.execute(run)
      assert finished.status == :failed
      assert finished.exit_code == 2
      assert finished.error_reason == nil
      assert finished.artifact_path == Path.join(run.id, "artifacts")
      assert {:ok, _log} = Runs.log(finished)
    end

    test "an oversized artifact output is recorded without changing the status", %{
      project: project,
      owner: owner,
      node: node,
      volume_path: volume_path
    } do
      Application.put_env(:cadence_server, :actions_max_artifact_bytes, 1)
      assert {:ok, run} = prepare(owner, project, node)
      out_dir = Path.join([volume_path, run.id, "out"])
      File.mkdir_p!(out_dir)

      FakeDocker.script(%{
        on_wait: fn -> File.write!(Path.join(out_dir, "big.bin"), "three") end
      })

      assert {:ok, finished} = Runs.execute(run)
      assert finished.status == :succeeded
      assert finished.artifact_path == nil
      assert finished.artifact_error == "too_large"
    end

    test "a timeout stops the container, records timed_out, and still removes it", %{
      project: project,
      owner: owner,
      node: node
    } do
      FakeDocker.script(%{wait: {:error, :timeout}})

      assert {:ok, run} = prepare(owner, project, node)
      assert {:ok, finished} = Runs.execute(run)

      assert finished.status == :timed_out
      assert finished.error_reason == "timeout"
      assert FakeDocker.calls(:stop) == [["container-1"]]
      assert FakeDocker.calls(:remove) == [["container-1"]]
    end

    test "a start failure removes the created container and skips wait/logs", %{
      project: project,
      owner: owner,
      node: node
    } do
      FakeDocker.script(%{start: {:error, :boom}})

      assert {:ok, run} = prepare(owner, project, node)
      assert {:ok, finished} = Runs.execute(run)

      assert finished.status == :failed
      assert finished.error_reason == "docker_unavailable"
      assert FakeDocker.calls(:wait) == []
      assert FakeDocker.calls(:logs) == []
      assert FakeDocker.calls(:remove) == [["container-1"]]
    end

    test "a create failure never starts a container", %{
      project: project,
      owner: owner,
      node: node
    } do
      FakeDocker.script(%{create: {:error, :boom}})

      assert {:ok, run} = prepare(owner, project, node)
      assert {:ok, finished} = Runs.execute(run)

      assert finished.status == :failed
      assert finished.error_reason == "docker_unavailable"
      assert FakeDocker.calls(:start) == []
      assert FakeDocker.calls(:remove) == []
    end

    test "a rejected create is reported as create_failed", %{
      project: project,
      owner: owner,
      node: node
    } do
      # Missing image, bad subpath, or an Engine too old for volume-subpath.
      FakeDocker.script(%{create: {:error, :create_failed}})

      assert {:ok, run} = prepare(owner, project, node)
      assert {:ok, finished} = Runs.execute(run)

      assert finished.status == :failed
      assert finished.error_reason == "create_failed"
      assert FakeDocker.calls(:start) == []
    end

    test "a non-timeout wait failure stops the container before collection", %{
      project: project,
      owner: owner,
      node: node
    } do
      FakeDocker.script(%{wait: {:error, :wait_failed}})

      assert {:ok, run} = prepare(owner, project, node)
      assert {:ok, finished} = Runs.execute(run)

      assert finished.status == :failed
      assert finished.error_reason == "run_failed"
      assert FakeDocker.calls(:stop) == [["container-1"]]
      assert FakeDocker.calls(:remove) == [["container-1"]]
    end

    test "a missing log is not a run failure", %{project: project, owner: owner, node: node} do
      FakeDocker.script(%{logs: {:error, :boom}})

      assert {:ok, run} = prepare(owner, project, node)
      assert {:ok, finished} = Runs.execute(run)

      assert finished.status == :succeeded
      assert finished.log_path == nil
      assert Runs.log(finished) == {:error, :not_found}
    end

    test "a missing Dockerfile and no project image is no_image", %{
      project: project,
      owner: owner
    } do
      node = F.node_with_snapshot(project, %{"actions/manifest.json" => @manifest})

      assert {:ok, run} = prepare(owner, project, node)
      assert {:ok, finished} = Runs.execute(run)

      assert finished.status == :failed
      assert finished.error_reason == "no_image"
      assert FakeDocker.calls(:create) == []
    end

    test "a project docker_image is reused without inspecting or building", %{
      project: project,
      owner: owner,
      node: node
    } do
      project =
        project
        |> Cadence.Shared.Project.changeset(%{docker_image: "alpine:3.20"})
        |> Repo.update!()

      assert {:ok, run} = prepare(owner, project, node)
      assert {:ok, finished} = Runs.execute(run)

      assert finished.status == :succeeded
      assert finished.image == "alpine:3.20"
      assert FakeDocker.calls(:image?) == []
      assert FakeDocker.calls(:build_image) == []
    end

    test "an absent image is built and tagged from the snapshot", %{
      project: project,
      owner: owner,
      node: node
    } do
      FakeDocker.script(%{image?: {:ok, false}})

      assert {:ok, run} = prepare(owner, project, node)
      assert {:ok, finished} = Runs.execute(run)

      assert finished.status == :succeeded
      assert finished.image == tag(project, node)
      assert [[tag_arg]] = FakeDocker.calls(:image?)
      assert tag_arg == tag(project, node)

      assert [[_code_dir, files, build_tag]] = FakeDocker.calls(:build_image)
      assert build_tag == tag(project, node)
      assert "Dockerfile" in files
      assert "actions/manifest.json" in files
    end

    test "a build failure is recorded as build_failed", %{
      project: project,
      owner: owner,
      node: node
    } do
      FakeDocker.script(%{image?: {:ok, false}, build_image: {:error, :boom}})

      assert {:ok, run} = prepare(owner, project, node)
      assert {:ok, finished} = Runs.execute(run)

      assert finished.status == :failed
      assert finished.error_reason == "build_failed"
      assert FakeDocker.calls(:create) == []
    end

    test "an unreachable daemon on the image check is docker_unavailable", %{
      project: project,
      owner: owner,
      node: node
    } do
      FakeDocker.script(%{image?: {:error, :boom}})

      assert {:ok, run} = prepare(owner, project, node)
      assert {:ok, finished} = Runs.execute(run)

      assert finished.status == :failed
      assert finished.error_reason == "docker_unavailable"
    end

    test "secret content quarantines the snapshot before any container", %{
      project: project,
      owner: owner
    } do
      node = F.node_with_snapshot(project, Map.put(snapshot_files(), ".env", "TOKEN=abc\n"))

      assert {:ok, run} = prepare(owner, project, node)
      assert {:ok, finished} = Runs.execute(run)

      assert finished.status == :failed
      assert finished.error_reason == "quarantined"
      assert FakeDocker.calls(:create) == []
    end

    test "a snapshot over the scan caps is quarantined, not staged", %{
      project: project,
      owner: owner,
      node: node
    } do
      Application.put_env(:cadence_server, :scan_max_files, 1)

      assert {:ok, run} = prepare(owner, project, node)
      assert {:ok, finished} = Runs.execute(run)

      assert finished.status == :failed
      assert finished.error_reason == "quarantined"
      assert FakeDocker.calls(:create) == []
    end

    test "a stale row is not executed twice", %{project: project, owner: owner, node: node} do
      assert {:ok, run} = prepare(owner, project, node)
      assert {:ok, first} = Runs.execute(run)
      assert first.status == :succeeded

      assert Runs.execute(run) == {:error, :stale}
      assert FakeDocker.calls(:create) |> length() == 1
    end
  end

  describe "prepare/4" do
    test "viewers may list actions but not run them", %{
      project: project,
      viewer: viewer,
      node: node
    } do
      assert Runs.prepare(%{id: viewer.id}, project.id, node.id, "run_analysis") ==
               {:error, :forbidden}
    end

    test "a membership from another project is forbidden", %{
      project: project,
      node: node
    } do
      other = F.project(Ecto.UUID.generate(), %{slug: "other-actions"})
      other_owner = seed_user("other-actions-owner@example.com")
      F.membership(other, other_owner.id, :owner)

      assert Runs.prepare(%{id: other_owner.id}, project.id, node.id, "run_analysis") ==
               {:error, :forbidden}
    end

    test "a node from another project is not found", %{project: project, owner: owner} do
      other = F.project(Ecto.UUID.generate(), %{slug: "other-node-project"})
      other_node = F.node_with_snapshot(other, snapshot_files())

      assert Runs.prepare(%{id: owner.id}, project.id, other_node.id, "run_analysis") ==
               {:error, :not_found}
    end

    test "an unknown action name is rejected before a row is written", %{
      project: project,
      owner: owner,
      node: node
    } do
      assert Runs.prepare(%{id: owner.id}, project.id, node.id, "nope") ==
               {:error, :unknown_action}

      assert Repo.aggregate(ActionRun, :count) == 0
    end

    test "the deployment switch disables runs", %{project: project, owner: owner, node: node} do
      Application.put_env(:cadence_server, :actions_enabled, false)

      assert Runs.prepare(%{id: owner.id}, project.id, node.id, "run_analysis") ==
               {:error, :disabled}
    end

    test "an open critical node incident blocks the run", %{
      project: project,
      owner: owner,
      node: node
    } do
      assert {:ok, _incident} =
               Incidents.open(%{
                 project_id: project.id,
                 node_id: node.id,
                 kind: :secret_detected,
                 severity: :critical,
                 title: "Secret detected",
                 details: %{}
               })

      assert Runs.prepare(%{id: owner.id}, project.id, node.id, "run_analysis") ==
               {:error, :quarantined}
    end
  end

  describe "start/4" do
    test "returns a queued row and broadcasts the terminal status", %{
      project: project,
      owner: owner,
      node: node
    } do
      Phoenix.PubSub.subscribe(Cadence.Server.PubSub, "project:" <> project.id)
      project_id = project.id

      assert {:ok, run} = Runs.start(%{id: owner.id}, project.id, node.id, "run_analysis")
      assert run.status == :queued

      assert_receive {:action_run_updated, ^project_id, run_id, :running}, 2_000
      assert run_id == run.id
      assert_receive {:action_run_updated, ^project_id, ^run_id, :succeeded}, 2_000

      assert Repo.get!(ActionRun, run.id).status == :succeeded
    end
  end

  describe "read APIs" do
    test "list/3 and get/3 are member-scoped", %{
      project: project,
      owner: owner,
      viewer: viewer,
      node: node
    } do
      assert {:ok, run} = prepare(owner, project, node)
      assert {:ok, _finished} = Runs.execute(run)

      assert {:ok, [listed]} = Runs.list(%{id: viewer.id}, project.id)
      assert listed.id == run.id
      assert {:ok, fetched} = Runs.get(%{id: viewer.id}, project.id, run.id)
      assert fetched.id == run.id

      assert Runs.list(%{id: Ecto.UUID.generate()}, project.id) == {:error, :forbidden}
      assert Runs.get(%{id: viewer.id}, project.id, Ecto.UUID.generate()) == {:error, :not_found}

      # A caller-supplied limit is clamped, never passed straight into Ecto.
      assert {:ok, _runs} = Runs.list(%{id: viewer.id}, project.id, limit: 0)
      assert {:ok, _runs} = Runs.list(%{id: viewer.id}, project.id, limit: "nope")
    end
  end

  describe "recover_stale/1" do
    test "marks abandoned rows interrupted, removes their containers, and broadcasts", %{
      project: project,
      owner: owner,
      node: node
    } do
      abandoned = insert_run(project, node, owner)
      recent = insert_run(project, node, owner)
      project_id = project.id
      abandoned_id = abandoned.id
      recent_id = recent.id

      old = DateTime.add(DateTime.utc_now(), -3_600_000, :millisecond)

      Repo.update_all(
        from(r in ActionRun, where: r.id == ^abandoned_id),
        set: [status: :running, updated_at: old, started_at: old, container_id: "container-old"]
      )

      Repo.update_all(
        from(r in ActionRun, where: r.id == ^recent_id),
        set: [status: :running]
      )

      Phoenix.PubSub.subscribe(Cadence.Server.PubSub, "project:" <> project_id)

      assert :ok = Runs.recover_stale(project_id)
      assert Repo.get!(ActionRun, abandoned_id).status == :interrupted
      assert Repo.get!(ActionRun, abandoned_id).error_reason == "interrupted"
      assert Repo.get!(ActionRun, recent_id).status == :running
      assert Repo.get!(ActionRun, abandoned_id).container_id == nil
      assert FakeDocker.calls(:remove) == [["container-old"]]
      assert_receive {:action_run_updated, ^project_id, ^abandoned_id, :interrupted}, 1_000
    end

    test "a failed removal keeps the container id for a later sweep", %{
      project: project,
      owner: owner,
      node: node
    } do
      run = insert_run(project, node, owner)
      run_id = run.id
      old = DateTime.add(DateTime.utc_now(), -3_600_000, :millisecond)

      Repo.update_all(
        from(r in ActionRun, where: r.id == ^run_id),
        set: [status: :running, updated_at: old, started_at: old, container_id: "container-old"]
      )

      FakeDocker.script(%{remove: {:error, :boom}})
      assert :ok = Runs.recover_stale(project.id)

      recovered = Repo.get!(ActionRun, run_id)
      assert recovered.status == :interrupted
      assert recovered.container_id == "container-old"

      # A later sweep retries the removal and clears the id once it succeeds.
      FakeDocker.script(%{remove: :ok})

      assert :ok = Runs.recover_all()
      assert Repo.get!(ActionRun, run_id).container_id == nil

      # recover_stale retried once inside the same call (row + orphan sweep),
      # then recover_all retried again; every attempt targeted the same id.
      assert length(FakeDocker.calls(:remove)) >= 2
      assert Enum.all?(FakeDocker.calls(:remove), &(&1 == ["container-old"]))
    end

    test "a terminal row whose removal failed is swept on the next pass", %{
      project: project,
      owner: owner,
      node: node
    } do
      run = insert_run(project, node, owner)
      run_id = run.id

      Repo.update_all(
        from(r in ActionRun, where: r.id == ^run_id),
        set: [status: :failed, error_reason: "run_failed", container_id: "container-dead"]
      )

      FakeDocker.script(%{remove: :ok})
      assert :ok = Runs.recover_all()

      assert Repo.get!(ActionRun, run_id).container_id == nil
      assert FakeDocker.calls(:remove) == [["container-dead"]]
    end
  end

  ## Helpers

  defp prepare(user, project, node) do
    Runs.prepare(%{id: user.id}, project.id, node.id, "run_analysis")
  end

  defp insert_run(project, node, user) do
    %ActionRun{}
    |> ActionRun.changeset(%{
      project_id: project.id,
      node_id: node.id,
      user_id: user.id,
      action_name: "run_analysis",
      command: "python actions/run.py"
    })
    |> Repo.insert!()
  end

  defp tag(project, node) do
    "cadence-action-#{project.slug}-#{String.slice(node.git_commit_sha, 0, 12)}"
  end

  defp snapshot_files do
    %{
      "Dockerfile" => @dockerfile,
      "actions/manifest.json" => @manifest,
      "actions/run.py" => "print('hi')\n"
    }
  end

  defp seed_user(email) do
    Ash.Seed.seed!(User, %{email: email, name: String.split(email, "@") |> hd()})
  end

  defp restore_env_keys do
    [:actions_docker, :actions_enabled, :scan_max_files, :actions_max_artifact_bytes]
  end

  defp previous_config do
    Map.new(restore_env_keys(), fn key -> {key, Application.get_env(:cadence_server, key)} end)
  end

  defp restore_config(previous) do
    Enum.each(previous, fn
      {key, nil} -> Application.delete_env(:cadence_server, key)
      {key, value} -> Application.put_env(:cadence_server, key, value)
    end)
  end
end
