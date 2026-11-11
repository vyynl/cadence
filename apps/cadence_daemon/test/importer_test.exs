defmodule Cadence.Daemon.ImporterTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Cadence.Daemon.{
    CommitQueue,
    ImportFixture,
    Importer,
    ProjectLocation,
    ProjectRegistry,
    Projects,
    Repo,
    Session,
    SyncPending
  }

  alias Cadence.Shared.{GitStore, Node, Project}

  setup do
    root =
      Path.join(System.tmp_dir!(), "cadence_importer_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    on_exit(fn ->
      ProjectLocation
      |> where([l], like(l.work_dir, ^"#{root}%"))
      |> Repo.all()
      |> Enum.each(&ProjectRegistry.stop_project(&1.project_id))

      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "imports a linear history with original SHAs, parents, dates, and metadata", %{root: root} do
    git = ImportFixture.worktree(root)
    c1 = ImportFixture.commit(git, %{"README.md" => "one"}, [], "first\n\nbody", 1_600_000_000)
    c2 = ImportFixture.commit(git, %{"README.md" => "two"}, [c1], "second", 1_600_000_100)

    c3 =
      ImportFixture.commit(
        git,
        %{"README.md" => "two", "new.txt" => "x"},
        [c2],
        "third",
        1_600_000_200
      )

    ImportFixture.write_ref(git, "refs/heads/main", c3)
    ImportFixture.write_worktree(git, %{"README.md" => "two", "new.txt" => "x"})

    job =
      import!(%{
        "work_dir" => ImportFixture.work_dir(git),
        "name" => "Linear",
        "slug" => slug()
      })

    assert job.status == :completed
    assert job.total == 3
    assert job.imported == 3
    assert job.reused == 0
    assert job.refs == ["refs/heads/main"]
    assert job.tips == [c3]
    assert job.shallow == false
    assert job.dirty_node_id == nil
    assert job.error == nil

    nodes = project_nodes(job.project_id)
    assert Enum.map(nodes, & &1.git_commit_sha) == [c1, c2, c3]
    [n1, n2, n3] = nodes

    assert n1.parents == []
    assert n2.parents == [n1.id]
    assert n3.parents == [n2.id]
    assert Enum.all?(nodes, &(&1.flags == []))
    assert Enum.all?(nodes, &(&1.docs_state == :skipped))
    assert Enum.map(nodes, & &1.pinned) == [false, false, true]
    assert Enum.map(nodes, & &1.message) == ["first\n\nbody", "second", "third"]
    assert DateTime.to_unix(n1.created_at) == 1_600_000_000
    assert job.tip_node_id == n3.id

    assert %{"import" => metadata} = n1.session_metadata
    assert metadata["source"] == "git"
    assert metadata["author"] == "A U Thor"
    assert metadata["author_email"] == "a@example.com"
    refute Map.has_key?(metadata, "refs")

    assert n3.session_metadata["import"]["refs"] == ["refs/heads/main"]

    assert Session.current_node(job.project_id).id == n3.id
    assert Repo.get(ProjectLocation, job.project_id).work_dir == ImportFixture.work_dir(git)
    assert ProjectRegistry.lookup_queue(job.project_id) != nil

    pending = Repo.all(from(p in SyncPending, where: p.project_id == ^job.project_id))
    assert length(pending) == 3
  end

  test "re-running the same import adds nothing", %{root: root} do
    {_git, attrs} = simple_import(root)
    job = import!(attrs)

    assert job.imported == 1

    rerun = import!(attrs)

    assert rerun.status == :completed
    assert rerun.imported == 0
    assert rerun.reused == 1
    assert rerun.tip_node_id == job.tip_node_id
    assert length(project_nodes(job.project_id)) == 1
  end

  test "preserves merge parents in order and lists every selected ref", %{root: root} do
    git = ImportFixture.worktree(root)
    c1 = ImportFixture.commit(git, %{"README.md" => "one"}, [], "root", 1_600_000_000)
    left = ImportFixture.commit(git, %{"README.md" => "left"}, [c1], "left", 1_600_000_100)
    right = ImportFixture.commit(git, %{"README.md" => "right"}, [c1], "right", 1_600_000_200)

    merge =
      ImportFixture.commit(
        git,
        %{"README.md" => "merged", "left.txt" => "l", "right.txt" => "r"},
        [left, right],
        "merge",
        1_600_000_300
      )

    ImportFixture.write_ref(git, "refs/heads/main", merge)
    ImportFixture.write_ref(git, "refs/heads/side", right)
    tag = ImportFixture.annotated_tag(git, left, "v1")
    ImportFixture.write_ref(git, "refs/tags/v1", tag)

    ImportFixture.write_worktree(git, %{
      "README.md" => "merged",
      "left.txt" => "l",
      "right.txt" => "r"
    })

    job =
      import!(%{
        "work_dir" => ImportFixture.work_dir(git),
        "all_refs" => true,
        "name" => "Merged",
        "slug" => slug()
      })

    assert job.imported == 4
    assert job.merge_commits == 1
    assert "refs/heads/main" in job.refs
    assert "refs/heads/side" in job.refs
    assert "refs/tags/v1" in job.refs
    refute "HEAD" in job.refs
    assert job.refs == Enum.uniq(job.refs)

    nodes = project_nodes(job.project_id)
    merge_node = Enum.find(nodes, &(&1.git_commit_sha == merge))
    left_node = Enum.find(nodes, &(&1.git_commit_sha == left))
    right_node = Enum.find(nodes, &(&1.git_commit_sha == right))

    assert merge_node.parents == [left_node.id, right_node.id]
  end

  test "resolves an annotated tag and imports only its history", %{root: root} do
    git = ImportFixture.bare(root, "tagrepo")
    c1 = ImportFixture.commit(git, %{"a.txt" => "1"}, [], "root", 1_600_000_000)
    left = ImportFixture.commit(git, %{"a.txt" => "left"}, [c1], "left", 1_600_000_100)
    right = ImportFixture.commit(git, %{"a.txt" => "right"}, [c1], "right", 1_600_000_200)

    merge =
      ImportFixture.commit(git, %{"a.txt" => "merged"}, [left, right], "merge", 1_600_000_300)

    ImportFixture.write_ref(git, "refs/heads/main", merge)
    tag = ImportFixture.annotated_tag(git, left, "v1")
    ImportFixture.write_ref(git, "refs/tags/v1", tag)

    job =
      import!(%{
        "work_dir" => git.home_dir,
        "refs" => ["v1"],
        "name" => "Tagged",
        "slug" => slug()
      })

    assert job.imported == 2
    assert job.refs == ["v1"]
    assert Enum.map(project_nodes(job.project_id), & &1.git_commit_sha) == [c1, left]
    assert ProjectRegistry.lookup_queue(job.project_id) == nil
  end

  test "rejects a shallow clone unless allow_shallow is set", %{root: root} do
    git = ImportFixture.bare(root, "shallow")
    missing = String.duplicate("0", 39) <> "1"

    boundary =
      ImportFixture.commit(git, %{"a.txt" => "a"}, [missing], "boundary", 1_600_000_000)

    ImportFixture.write_head(git, boundary)
    ImportFixture.write_shallow(git, [boundary])

    assert {:error, :shallow_repository} =
             Importer.submit(%{"work_dir" => git.home_dir, "slug" => slug()})

    assert Repo.get_by(ProjectLocation, work_dir: git.home_dir) == nil

    job =
      import!(%{
        "work_dir" => git.home_dir,
        "allow_shallow" => true,
        "name" => "Shallow",
        "slug" => slug()
      })

    assert job.shallow == true
    assert job.imported == 1
    assert [node] = project_nodes(job.project_id)
    assert node.parents == []

    # The deployment default applies when the request omits the flag.
    config_git = ImportFixture.bare(root, "shallow-config")

    config_boundary =
      ImportFixture.commit(config_git, %{"b.txt" => "b"}, [missing], "boundary", 1_600_000_000)

    ImportFixture.write_head(config_git, config_boundary)
    ImportFixture.write_shallow(config_git, [config_boundary])

    on_exit(fn -> Application.delete_env(:cadence_daemon, :import_allow_shallow) end)
    Application.put_env(:cadence_daemon, :import_allow_shallow, true)

    config_job =
      import!(%{
        "work_dir" => config_git.home_dir,
        "name" => "Shallow Config",
        "slug" => slug()
      })

    assert config_job.shallow == true
    assert config_job.imported == 1
  end

  test "a history above the limit is a typed error and creates no project", %{root: root} do
    git = ImportFixture.worktree(root)
    c1 = ImportFixture.commit(git, %{"a" => "1"}, [], "one", 1_600_000_000)
    c2 = ImportFixture.commit(git, %{"a" => "2"}, [c1], "two", 1_600_000_100)
    c3 = ImportFixture.commit(git, %{"a" => "3"}, [c2], "three", 1_600_000_200)
    ImportFixture.write_ref(git, "refs/heads/main", c3)

    assert {:error, {:too_many_commits, 2}} =
             Importer.submit(%{
               "work_dir" => ImportFixture.work_dir(git),
               "limit" => 2,
               "slug" => slug()
             })

    assert Repo.get_by(ProjectLocation, work_dir: ImportFixture.work_dir(git)) == nil
  end

  test "preflights large blobs before creating a project", %{root: root} do
    git = ImportFixture.worktree(root)

    sha =
      ImportFixture.commit(
        git,
        %{"big.bin" => String.duplicate("x", 100)},
        [],
        "big",
        1_600_000_000
      )

    ImportFixture.write_ref(git, "refs/heads/main", sha)
    ImportFixture.write_worktree(git, %{"big.bin" => String.duplicate("x", 100)})

    on_exit(fn -> Application.delete_env(:cadence_daemon, :import_max_blob_bytes) end)
    Application.put_env(:cadence_daemon, :import_max_blob_bytes, 10)

    assert {:error, {:blob_too_large, "big.bin", 100}} =
             Importer.submit(%{"work_dir" => ImportFixture.work_dir(git), "slug" => slug()})

    assert Repo.get_by(ProjectLocation, work_dir: ImportFixture.work_dir(git)) == nil
  end

  test "refuses a project that already has non-imported nodes", %{root: root} do
    git = ImportFixture.worktree(root, "manual")
    sha = ImportFixture.commit(git, %{"README.md" => "one"}, [], "one", 1_600_000_000)
    ImportFixture.write_ref(git, "refs/heads/main", sha)
    ImportFixture.write_worktree(git, %{"README.md" => "one"})
    work_dir = ImportFixture.work_dir(git)

    {:ok, project} =
      Projects.register_project(%{"name" => "Manual", "slug" => slug(), "work_dir" => work_dir})

    queue = ProjectRegistry.lookup_queue(project.id)
    {:ok, _node} = CommitQueue.commit(queue, "manual work")

    assert {:error, :project_not_importable} = Importer.submit(%{"work_dir" => work_dir})
  end

  test "rejects a mismatched or unknown project id", %{root: root} do
    {git, _attrs} = simple_import(root)
    other = Path.join(root, "other")
    File.mkdir_p!(other)

    {:ok, project} =
      Projects.register_project(%{"name" => "Other", "slug" => slug(), "work_dir" => other})

    assert {:error, :project_location_mismatch} =
             Importer.submit(%{
               "work_dir" => ImportFixture.work_dir(git),
               "project_id" => project.id
             })

    assert {:error, :project_not_found} =
             Importer.submit(%{
               "work_dir" => ImportFixture.work_dir(git),
               "project_id" => Ecto.UUID.generate()
             })

    assert {:error, :invalid_project} =
             Importer.submit(%{
               "work_dir" => ImportFixture.work_dir(git),
               "project_id" => "not-a-uuid"
             })
  end

  test "validates the source path", %{root: root} do
    not_a_repo = Path.join(root, "plain")
    File.mkdir_p!(not_a_repo)

    assert {:error, :missing_work_dir} = Importer.submit(%{})
    assert {:error, :not_a_directory} = Importer.submit(%{"work_dir" => not_a_repo <> "/nope"})
    assert {:error, :not_a_repository} = Importer.submit(%{"work_dir" => not_a_repo})
    assert {:error, :invalid_payload} = Importer.submit(:not_a_map)
    assert {:error, :not_found} = Importer.status("not-a-uuid")
    assert {:error, :not_found} = Importer.status(Ecto.UUID.generate())
  end

  test "commits a dirty working tree once against the imported tip", %{root: root} do
    git = ImportFixture.worktree(root)
    c1 = ImportFixture.commit(git, %{"README.md" => "one"}, [], "base", 1_600_000_000)
    ImportFixture.write_ref(git, "refs/heads/main", c1)
    ImportFixture.write_worktree(git, %{"README.md" => "edited"})

    job =
      import!(%{
        "work_dir" => ImportFixture.work_dir(git),
        "name" => "Dirty",
        "slug" => slug()
      })

    assert job.imported == 1
    assert job.tip_node_id != nil
    assert job.dirty_node_id != nil

    nodes = project_nodes(job.project_id)
    assert length(nodes) == 2

    dirty = Enum.find(nodes, &(&1.id == job.dirty_node_id))
    assert dirty.parents == [job.tip_node_id]
    assert dirty.message == "import: local changes"
    assert Session.current_node(job.project_id).id == dirty.id

    # A re-run does not rewind the pointer or duplicate the dirty node.
    rerun =
      import!(%{
        "work_dir" => ImportFixture.work_dir(git),
        "name" => "Dirty",
        "slug" => slug()
      })

    assert rerun.status == :completed
    assert rerun.dirty_node_id == nil
    assert Session.current_node(job.project_id).id == dirty.id
    assert length(project_nodes(job.project_id)) == 2
  end

  test "a job past its time bound is stopped and reported", %{root: root} do
    {_git, attrs} = simple_import(root)

    {:ok, project} =
      Projects.register_project(%{
        "name" => "Timeout",
        "slug" => slug(),
        "work_dir" => attrs["work_dir"]
      })

    attrs = Map.put(attrs, "project_id", project.id)

    on_exit(fn ->
      Application.delete_env(:cadence_daemon, :import_runner)
      Application.delete_env(:cadence_daemon, :import_max_seconds)
    end)

    Application.put_env(:cadence_daemon, :import_runner, fn plan, _progress ->
      Cadence.Daemon.Watcher.suspend(plan.project_id, {:import, plan.job_id})
      Process.sleep(:infinity)
    end)

    Application.put_env(:cadence_daemon, :import_max_seconds, 1)

    {:ok, queued} = Importer.submit(attrs)
    job = await(queued.id, 5_000)

    assert job.status == :failed
    assert job.error.code == "timeout"
    refute Cadence.Daemon.Watcher.suspended?(project.id)
  end

  test "derives a project name and slug from the source path", %{root: root} do
    name = "repo-#{System.unique_integer([:positive])}"
    git = ImportFixture.worktree(root, name)
    sha = ImportFixture.commit(git, %{"README.md" => "one"}, [], "one", 1_600_000_000)
    ImportFixture.write_ref(git, "refs/heads/main", sha)
    ImportFixture.write_worktree(git, %{"README.md" => "one"})

    job = import!(%{"work_dir" => ImportFixture.work_dir(git)})

    assert job.status == :completed
    assert job.project_slug == name
    assert Repo.get(Project, job.project_id).name == name
  end

  test "sanitizes a non-UTF-8 commit message", %{root: root} do
    git = ImportFixture.worktree(root)
    message = "caf\xE9"
    sha = ImportFixture.commit(git, %{"README.md" => "one"}, [], message, 1_600_000_000)
    ImportFixture.write_ref(git, "refs/heads/main", sha)
    ImportFixture.write_worktree(git, %{"README.md" => "one"})

    job = import!(%{"work_dir" => ImportFixture.work_dir(git), "slug" => slug()})

    assert [node] = project_nodes(job.project_id)
    assert String.valid?(node.message)
    assert node.message == "caf\uFFFD"
  end

  test "an unreadable commit object is a typed error, not a crash", %{root: root} do
    git = ImportFixture.bare(root, "malformed")

    bad =
      GitStore.write_raw(
        git,
        :commit,
        "tree #{String.duplicate("0", 40)}\nauthor garbage\n\nmsg\n"
      )

    ImportFixture.write_head(git, bad)

    assert {:error, {:invalid_source, :unreadable_object}} =
             Importer.submit(%{"work_dir" => git.home_dir, "slug" => slug()})

    assert Repo.get_by(ProjectLocation, work_dir: git.home_dir) == nil
  end

  defp simple_import(root) do
    git = ImportFixture.worktree(root)
    sha = ImportFixture.commit(git, %{"README.md" => "one"}, [], "one", 1_600_000_000)
    ImportFixture.write_ref(git, "refs/heads/main", sha)
    ImportFixture.write_worktree(git, %{"README.md" => "one"})

    {git, %{"work_dir" => ImportFixture.work_dir(git), "name" => "Simple", "slug" => slug()}}
  end

  defp import!(attrs) do
    {:ok, job} = Importer.submit(attrs)
    await(job.id)
  end

  defp await(job_id, timeout \\ 15_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(job_id, deadline)
  end

  defp do_await(job_id, deadline) do
    {:ok, job} = Importer.status(job_id)

    cond do
      job.status in [:completed, :failed] ->
        job

      System.monotonic_time(:millisecond) > deadline ->
        flunk("import #{job_id} did not finish (status: #{job.status})")

      true ->
        Process.sleep(10)
        do_await(job_id, deadline)
    end
  end

  defp project_nodes(project_id) do
    Node
    |> where([n], n.project_id == ^project_id)
    |> order_by([n], asc: n.created_at, asc: n.id)
    |> Repo.all()
  end

  defp slug, do: "import-#{System.unique_integer([:positive])}"
end
