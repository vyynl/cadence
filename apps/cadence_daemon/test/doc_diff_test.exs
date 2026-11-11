defmodule Cadence.Daemon.DocDiffTest do
  use ExUnit.Case, async: false

  alias Cadence.Daemon.{CommitQueue, DocDiff, ProjectLocation, Repo}
  alias Cadence.Shared.{GitStore, Node, Project}

  @schema """
  index_file: README.md
  docs_dir: docs
  sections:
    - name: Overview
      required: true
      generated_from: "lib/**/*.ex"
  """

  setup do
    root = Path.join(System.tmp_dir!(), "cadence_docdiff_#{System.unique_integer([:positive])}")
    work_dir = Path.join(root, "work")
    git_dir = Path.join(root, "git")
    File.mkdir_p!(work_dir)

    project = insert_project()
    insert_location(project.id, work_dir, git_dir)

    Application.put_env(:cadence_daemon, :docs_llm, Cadence.Daemon.TestDocsLLM)
    Application.put_env(:cadence_daemon, :docs_rate_limit, 1_000)

    on_exit(fn ->
      File.rm_rf!(root)
      Application.delete_env(:cadence_daemon, :docs_llm)
      Application.delete_env(:cadence_daemon, :docs_rate_limit)
      Application.delete_env(:cadence_daemon, :test_docs_llm_result)
    end)

    %{root: root, work_dir: work_dir, git_dir: git_dir, project: project}
  end

  test "returns the doc-only diff between the code and docs commits", ctx do
    queue =
      start_supervised!(
        {CommitQueue, [project_id: ctx.project.id, work_dir: ctx.work_dir, git_dir: ctx.git_dir]}
      )

    File.write!(Path.join(ctx.work_dir, ".caddocs.yaml"), @schema)
    File.mkdir_p!(Path.join(ctx.work_dir, "lib"))
    File.write!(Path.join(ctx.work_dir, "lib/demo.ex"), "defmodule Demo do\nend\n")

    {:ok, node} = CommitQueue.commit(queue, "code")

    assert eventually(fn -> Repo.get!(Node, node.id).docs_state == :current end)

    assert {:ok, diff} = DocDiff.build(ctx.project.id, node.id)
    assert Enum.map(diff.files, & &1.path) == ["README.md"]
    assert Enum.map(diff.files, & &1.status) == [:added]
    assert diff.code_commit_sha == node.git_commit_sha
    refute diff.docs_commit_sha == node.git_commit_sha
  end

  test "returns no_docs_commit for a code-only node", ctx do
    queue =
      start_supervised!(
        {CommitQueue, [project_id: ctx.project.id, work_dir: ctx.work_dir, git_dir: ctx.git_dir]}
      )

    File.write!(Path.join(ctx.work_dir, "a.txt"), "hi\n")
    {:ok, node} = CommitQueue.commit(queue, "code")

    assert node.docs_state == :skipped
    assert DocDiff.build(ctx.project.id, node.id) == {:error, :no_docs_commit}
  end

  test "falls back to the first logical parent when code_commit_sha is absent", ctx do
    git = GitStore.init(ctx.git_dir, bare: true)

    {:ok, parent_tree} = GitStore.put_files(git, %{"README.md" => "# Project\n"})
    parent_sha = GitStore.write_commit(git, parent_tree, [], author(), "parent")

    parent =
      insert_node(ctx.project, %{
        git_commit_sha: parent_sha,
        parents: [],
        docs_state: :current
      })

    {:ok, child_tree} =
      GitStore.merge_files(git, parent_tree, %{
        "docs/guide.md" => "guide\n",
        "src/app.ex" => "defmodule App do\nend\n"
      })

    child_sha = GitStore.write_commit(git, child_tree, [parent_sha], author(), "docs")

    child =
      insert_node(ctx.project, %{
        git_commit_sha: child_sha,
        parents: [parent.id],
        docs_state: :current
      })

    File.write!(Path.join(ctx.work_dir, ".caddocs.yaml"), @schema)

    assert {:ok, diff} = DocDiff.build(ctx.project.id, child.id)
    assert diff.code_commit_sha == nil
    assert diff.docs_commit_sha == child_sha
    assert Enum.map(diff.files, & &1.path) == ["docs/guide.md"]
  end

  defp insert_project do
    {:ok, project} =
      %{
        name: "p",
        slug: "p-#{System.unique_integer([:positive])}",
        owner_id: Ecto.UUID.generate()
      }
      |> Project.changeset()
      |> Repo.insert()

    project
  end

  defp insert_location(project_id, work_dir, git_dir) do
    %ProjectLocation{}
    |> ProjectLocation.changeset(%{
      project_id: project_id,
      work_dir: work_dir,
      git_dir: git_dir,
      created_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp insert_node(project, attrs) do
    attrs
    |> Map.merge(%{
      project_id: project.id,
      flags: [:"in-progress"],
      message: "m",
      created_by: project.owner_id,
      created_at: DateTime.utc_now()
    })
    |> Node.changeset()
    |> Repo.insert!()
  end

  defp author, do: %{name: "cadence", email: "cadence@local"}

  defp eventually(fun), do: Cadence.Daemon.TestHelpers.eventually(fun, 5_000)
end
