defmodule Cadence.Server.Actions.CleanupTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Cadence.Server.{ActionRun, Repo}
  alias Cadence.Server.Accounts.User
  alias Cadence.Server.Actions.{Cleanup, Retention}
  alias Cadence.Server.FakeDocker
  alias Cadence.ServerFixtures, as: F

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    previous = previous_config()
    on_exit(fn -> restore_config(previous) end)

    Application.put_env(:cadence_server, :actions_docker, FakeDocker)
    FakeDocker.setup()

    artifact_path = Application.fetch_env!(:cadence_server, :artifact_path)
    File.rm_rf!(artifact_path)
    File.mkdir_p!(artifact_path)

    project = F.project(Ecto.UUID.generate(), %{slug: "cleanup"})
    other = F.project(Ecto.UUID.generate(), %{slug: "cleanup-other"})
    owner = Ash.Seed.seed!(User, %{email: "cleanup-owner@example.com", name: "Owner"})
    F.membership(project, owner.id, :owner)

    %{project: project, other: other, owner: owner, artifact_path: artifact_path}
  end

  describe "sweep/1" do
    test "an old terminal run loses its directory and paths but keeps its row", %{
      project: project,
      owner: owner,
      artifact_path: artifact_path
    } do
      run = insert_run(project, owner)
      dir = write_artifacts(artifact_path, run)

      finish(run, 40,
        log_path: Path.join(run.id, "output.log"),
        artifact_path: Path.join(run.id, "artifacts"),
        artifact_error: "collect_skipped"
      )

      assert %{swept: 1, failed: 0} = Cleanup.sweep(days: 30)
      refute File.exists?(dir)

      row = Repo.get!(ActionRun, run.id)
      assert row.status == :succeeded
      assert row.exit_code == 0
      assert row.log_path == nil
      assert row.artifact_path == nil
      assert row.artifact_error == "collect_skipped"
    end

    test "a recent terminal run is kept", %{
      project: project,
      owner: owner,
      artifact_path: artifact_path
    } do
      run = insert_run(project, owner)
      dir = write_artifacts(artifact_path, run)
      log_path = Path.join(run.id, "output.log")
      artifacts = Path.join(run.id, "artifacts")

      finish(run, 1, log_path: log_path, artifact_path: artifacts)

      assert %{swept: 0, failed: 0} = Cleanup.sweep(days: 30)
      assert File.exists?(dir)

      row = Repo.get!(ActionRun, run.id)
      assert row.log_path == log_path
      assert row.artifact_path == artifacts
    end

    test "queued and running rows are never swept", %{
      project: project,
      owner: owner,
      artifact_path: artifact_path
    } do
      queued = insert_run(project, owner)
      queued_dir = write_artifacts(artifact_path, queued)
      backdate(queued, :queued, 40, log_path: Path.join(queued.id, "output.log"))

      running = insert_run(project, owner)
      running_dir = write_artifacts(artifact_path, running)
      backdate(running, :running, 40, log_path: Path.join(running.id, "output.log"))

      assert %{swept: 0, failed: 0} = Cleanup.sweep(days: 30)
      assert File.exists?(queued_dir)
      assert File.exists?(running_dir)
      assert Repo.get!(ActionRun, queued.id).log_path != nil
      assert Repo.get!(ActionRun, running.id).log_path != nil
    end

    test "a missing directory still clears the recorded paths", %{
      project: project,
      owner: owner
    } do
      run = insert_run(project, owner)

      finish(run, 40,
        log_path: Path.join(run.id, "output.log"),
        artifact_path: Path.join(run.id, "artifacts")
      )

      assert %{swept: 1, failed: 0} = Cleanup.sweep(days: 30)
      assert Repo.get!(ActionRun, run.id).log_path == nil
    end

    test "a non-positive window disables the sweep", %{
      project: project,
      owner: owner,
      artifact_path: artifact_path
    } do
      run = insert_run(project, owner)
      dir = write_artifacts(artifact_path, run)
      finish(run, 40, log_path: Path.join(run.id, "output.log"))

      assert %{swept: 0, failed: 0} = Cleanup.sweep(days: 0)
      assert File.exists?(dir)
      assert Repo.get!(ActionRun, run.id).log_path != nil
    end

    test "the batch cap leaves the remainder for the next pass", %{
      project: project,
      owner: owner,
      artifact_path: artifact_path
    } do
      runs =
        for _ <- 1..3 do
          run = insert_run(project, owner)
          write_artifacts(artifact_path, run)
          finish(run, 40, log_path: Path.join(run.id, "output.log"))
        end

      assert %{swept: 2, failed: 0} = Cleanup.sweep(days: 30, batch: 2)
      assert %{swept: 1, failed: 0} = Cleanup.sweep(days: 30, batch: 2)
      assert %{swept: 0, failed: 0} = Cleanup.sweep(days: 30, batch: 2)

      assert Enum.count(runs, fn run -> Repo.get!(ActionRun, run.id).log_path == nil end) == 3
    end

    test "a failed removal keeps the paths for the next pass", %{
      project: project,
      owner: owner,
      artifact_path: artifact_path
    } do
      run = insert_run(project, owner)
      write_artifacts(artifact_path, run)
      log_path = Path.join(run.id, "output.log")
      finish(run, 40, log_path: log_path)

      # 0o500 on the artifact root blocks unlinking its entries (the test user
      # is not root), which is the failure path a read-only volume produces.
      File.chmod!(artifact_path, 0o500)
      on_exit(fn -> File.chmod!(artifact_path, 0o700) end)

      assert %{swept: 0, failed: 1} = Cleanup.sweep(days: 30)
      assert Repo.get!(ActionRun, run.id).log_path == log_path

      File.chmod!(artifact_path, 0o700)

      assert %{swept: 1, failed: 0} = Cleanup.sweep(days: 30)
      assert Repo.get!(ActionRun, run.id).log_path == nil
    end
  end

  describe "prune_images/1" do
    test "keeps the newest N per project and ignores unrelated images" do
      FakeDocker.script(%{
        list_images:
          {:ok,
           [
             image("cadence-action-cleanup-aaaaaaaaaaaa", 400),
             image("cadence-action-cleanup-bbbbbbbbbbbb", 300),
             image("cadence-action-cleanup-cccccccccccc", 200),
             # This slug prefixes "cleanup"; the longest match must own it.
             image("cadence-action-cleanup-other-dddddddddddd", 150),
             image("cadence-action-cleanup-other-eeeeeeeeeeee", 50),
             image("cadence-action-cleanup-other-ffffffffffff", 25),
             image("unrelated/image:latest", 10)
           ]}
      })

      assert %{removed: 2, failed: 0} = Cleanup.prune_images(keep_images: 2)

      assert Enum.sort(FakeDocker.calls(:remove_image)) == [
               ["cadence-action-cleanup-cccccccccccc"],
               ["cadence-action-cleanup-other-ffffffffffff"]
             ]
    end

    test "a zero keep count disables image pruning before Docker is consulted" do
      assert %{removed: 0, failed: 0} = Cleanup.prune_images(keep_images: 0)
      assert FakeDocker.calls(:list_images) == []
    end

    test "Docker being unavailable skips the image half" do
      FakeDocker.script(%{list_images: {:error, :boom}})

      assert %{removed: 0, failed: 0} = Cleanup.prune_images(keep_images: 1)
    end

    test "a failed removal is counted and does not stop the pass" do
      FakeDocker.script(%{
        list_images:
          {:ok,
           [
             image("cadence-action-cleanup-aaaaaaaaaaaa", 400),
             image("cadence-action-cleanup-bbbbbbbbbbbb", 300),
             image("cadence-action-cleanup-cccccccccccc", 200)
           ]},
        remove_image: {:error, :remove_failed}
      })

      assert %{removed: 0, failed: 1} = Cleanup.prune_images(keep_images: 2)
    end
  end

  describe "run/1" do
    test "a held cleanup lock returns busy, then a later pass succeeds" do
      config = Repo.config()

      {:ok, conn} =
        Postgrex.start_link(
          hostname: config[:hostname],
          port: config[:port],
          username: config[:username],
          password: config[:password],
          database: config[:database]
        )

      on_exit(fn -> if Process.alive?(conn), do: GenServer.stop(conn) end)
      Postgrex.query!(conn, "SELECT pg_advisory_lock(hashtext('cadence.actions_cleanup'))", [])

      assert Cleanup.run(days: 30) == {:error, :busy}
      # A busy pass skips both halves.
      assert FakeDocker.calls(:list_images) == []

      Postgrex.query!(conn, "SELECT pg_advisory_unlock(hashtext('cadence.actions_cleanup'))", [])
      GenServer.stop(conn)

      assert {:ok, %{artifacts: %{swept: 0, failed: 0}, images: %{removed: 0, failed: 0}}} =
               Cleanup.run(days: 30)
    end
  end

  describe "Retention" do
    test "calls the injected sweep on the interval" do
      parent = self()
      name = :"retention_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Retention.start_link(
          name: name,
          enabled: true,
          interval_ms: 20,
          runner: fn -> send(parent, :swept) end
        )

      assert_receive :swept, 1_000
      GenServer.stop(pid)
    end

    test "a disabled or zero-interval worker never sweeps" do
      parent = self()
      runner = fn -> send(parent, :swept) end
      name = :"retention_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Retention.start_link(name: name, enabled: false, interval_ms: 20, runner: runner)

      refute_receive :swept, 80
      GenServer.stop(pid)

      other = :"retention_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Retention.start_link(name: other, enabled: true, interval_ms: 0, runner: runner)

      refute_receive :swept, 80
      GenServer.stop(pid)
    end

    test "a crashing sweep is contained and the process stays up" do
      name = :"retention_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Retention.start_link(
          name: name,
          enabled: true,
          interval_ms: 20,
          runner: fn -> raise "boom" end
        )

      Process.sleep(60)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  ## Helpers

  defp insert_run(project, owner) do
    %ActionRun{}
    |> ActionRun.changeset(%{
      project_id: project.id,
      node_id: Ecto.UUID.generate(),
      user_id: owner.id,
      action_name: "run_analysis",
      command: "true"
    })
    |> Repo.insert!()
  end

  defp finish(run, age_days, attrs) do
    timestamp = DateTime.add(DateTime.utc_now(), -age_days * 86_400, :second)

    from(r in ActionRun, where: r.id == ^run.id)
    |> Repo.update_all(
      set:
        Keyword.merge(
          [status: :succeeded, exit_code: 0, finished_at: timestamp, updated_at: timestamp],
          attrs
        )
    )

    Repo.get!(ActionRun, run.id)
  end

  defp backdate(run, status, age_days, attrs) do
    timestamp = DateTime.add(DateTime.utc_now(), -age_days * 86_400, :second)

    from(r in ActionRun, where: r.id == ^run.id)
    |> Repo.update_all(
      set:
        Keyword.merge(
          [status: status, started_at: timestamp, updated_at: timestamp],
          attrs
        )
    )
  end

  defp write_artifacts(root, run) do
    dir = Path.join(root, run.id)
    File.mkdir_p!(Path.join(dir, "artifacts"))
    File.write!(Path.join(dir, "output.log"), "log\n")
    File.write!(Path.join(dir, "artifacts/report.txt"), "ok\n")
    dir
  end

  defp image(tag, created_at) do
    %{tags: [tag], created_at: created_at, id: "sha256:#{created_at}"}
  end

  defp previous_config do
    keys = [
      :actions_docker,
      :actions_enabled,
      :artifact_path,
      :actions_artifact_retention_days,
      :actions_retention_batch,
      :actions_image_retention_per_project
    ]

    Map.new(keys, fn key -> {key, Application.get_env(:cadence_server, key)} end)
  end

  defp restore_config(previous) do
    Enum.each(previous, fn
      {key, nil} -> Application.delete_env(:cadence_server, key)
      {key, value} -> Application.put_env(:cadence_server, key, value)
    end)
  end
end
