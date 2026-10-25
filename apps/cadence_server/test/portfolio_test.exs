defmodule Cadence.Server.PortfolioTest do
  use ExUnit.Case, async: false

  alias Cadence.Server.{Portfolio, ProjectGit, Repo}
  alias Cadence.Shared.{GitStore, Membership, Node, Project}

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  describe "get_project_by_slug/1" do
    test "returns the project" do
      project = insert_project("demo")

      assert {:ok, found} = Portfolio.get_project_by_slug("demo")
      assert found.id == project.id
    end

    test "returns :not_found for unknown or invalid slugs" do
      assert Portfolio.get_project_by_slug("missing") == {:error, :not_found}
      assert Portfolio.get_project_by_slug(nil) == {:error, :not_found}
    end
  end

  describe "list_nodes/1" do
    test "orders newest first and breaks timestamp ties by id" do
      project = insert_project()
      at = ~U[2026-10-24 12:00:00.000000Z]

      first =
        insert_node(project, %{
          id: "00000000-0000-0000-0000-000000000001",
          message: "first",
          created_at: at
        })

      second =
        insert_node(project, %{
          id: "00000000-0000-0000-0000-000000000002",
          message: "second",
          created_at: at
        })

      assert Enum.map(Portfolio.list_nodes(project.id), & &1.id) == [second.id, first.id]
    end

    test "returns [] for an invalid project id" do
      assert Portfolio.list_nodes("not-a-uuid") == []
    end
  end

  describe "preview_node/1" do
    test "prefers a pinned node over a newer functioning node" do
      project = insert_project()

      pinned =
        insert_node(project, %{
          pinned: true,
          message: "pinned",
          created_at: ~U[2026-10-20 00:00:00Z]
        })

      insert_node(project, %{
        flags: [:functioning],
        message: "functioning",
        created_at: ~U[2026-10-24 00:00:00Z]
      })

      assert Portfolio.preview_node(project.id).id == pinned.id
    end

    test "prefers a functioning node over a newer in-progress node" do
      project = insert_project()

      functioning =
        insert_node(project, %{
          flags: [:functioning],
          message: "functioning",
          created_at: ~U[2026-10-20 00:00:00Z]
        })

      insert_node(project, %{
        flags: [:"in-progress"],
        message: "in progress",
        created_at: ~U[2026-10-24 00:00:00Z]
      })

      assert Portfolio.preview_node(project.id).id == functioning.id
    end

    test "falls back to the newest node" do
      project = insert_project()

      insert_node(project, %{
        flags: [:"in-progress"],
        message: "older",
        created_at: ~U[2026-10-20 00:00:00Z]
      })

      newest =
        insert_node(project, %{
          flags: [:broken],
          message: "newest",
          created_at: ~U[2026-10-24 00:00:00Z]
        })

      assert Portfolio.preview_node(project.id).id == newest.id
    end

    test "returns nil when the project has no nodes" do
      project = insert_project()
      assert Portfolio.preview_node(project.id) == nil
    end

    test "returns nil for an invalid project id" do
      assert Portfolio.preview_node("not-a-uuid") == nil
    end
  end

  describe "repository snapshots" do
    setup do
      project = insert_project("repo")

      clean =
        insert_node_with_files(project, %{message: "clean"}, %{
          "README.md" => "# Hello\n\nWelcome.\n",
          "docs/guide.md" => "guide\n",
          "src/app.ex" => "defmodule App do\nend\n",
          "bin.dat" => <<0, 1, 2>>,
          "large.txt" => String.duplicate("x", 5000)
        })

      secret =
        insert_node_with_files(project, %{message: "secret"}, %{
          "README.md" => "# Secret\n\ntoken: ghp_abcdefghijklmnopqrstuvwxyz0123456789\n",
          "config.txt" => "token: ghp_abcdefghijklmnopqrstuvwxyz0123456789\n"
        })

      env =
        insert_node_with_files(project, %{message: "env"}, %{
          ".env" => "SAFE=1\n",
          "README.md" => "# Env\n"
        })

      example =
        insert_node_with_files(project, %{message: "example"}, %{
          ".env.example" => "TOKEN=placeholder\n",
          "README.md" => "# Example\n"
        })

      %{project: project, clean: clean, secret: secret, env: env, example: example}
    end

    test "lists directories and files with filtering", %{project: project, clean: clean} do
      assert {:ok, dir} = Portfolio.list_dir(project, clean, "")
      assert dir.hidden_count == 0
      refute dir.truncated?

      assert Enum.map(dir.entries, & &1.name) == [
               "docs",
               "src",
               "bin.dat",
               "large.txt",
               "README.md"
             ]

      assert {:ok, docs} = Portfolio.list_dir(project, clean, "docs")
      assert Enum.map(docs.entries, & &1.name) == ["guide.md"]

      assert {:error, :not_found} = Portfolio.list_dir(project, clean, "missing")
    end

    test "hides sensitive paths from a listing", %{project: project, env: env} do
      assert {:ok, dir} = Portfolio.list_dir(project, env, "")
      assert dir.hidden_count == 1
      refute Enum.any?(dir.entries, &(&1.name == ".env"))
    end

    test "quarantines secrets, sensitive paths, and unverifiable snapshots", %{
      project: project,
      clean: clean,
      secret: secret,
      env: env,
      example: example
    } do
      assert Portfolio.quarantine_status(project, clean) == :ok
      assert Portfolio.quarantine_status(project, secret) == :quarantined
      assert Portfolio.quarantine_status(project, env) == :quarantined
      assert Portfolio.quarantine_status(project, example) == :ok

      missing = %{clean | git_commit_sha: String.duplicate("0", 40)}
      assert Portfolio.quarantine_status(project, missing) == :quarantined
    end

    test "reads and redacts files", %{project: project, clean: clean, secret: secret, env: env} do
      assert {:ok, file} = Portfolio.read_file(project, clean, "src/app.ex")
      assert file.content == "defmodule App do\nend\n"
      refute file.redacted?

      assert {:ok, redacted} = Portfolio.read_file(project, secret, "config.txt")
      assert redacted.redacted?
      refute redacted.content =~ "ghp_"
      assert redacted.content =~ "[REDACTED]"

      assert {:error, :not_found} = Portfolio.read_file(project, clean, "missing.txt")
      assert {:error, :hidden} = Portfolio.read_file(project, env, ".env")
    end

    test "handles binary, oversized, and line-truncated files", %{
      project: project,
      clean: clean
    } do
      assert {:ok, binary} = Portfolio.read_file(project, clean, "bin.dat")
      assert binary.binary?
      assert is_nil(binary.content)

      assert {:ok, large} = Portfolio.read_file(project, clean, "large.txt")
      assert large.truncated?
      assert is_nil(large.content)

      long =
        insert_node_with_files(project, %{message: "long"}, %{
          "long.txt" => Enum.map_join(1..150, "\n", &"line #{&1}")
        })

      assert {:ok, truncated} = Portfolio.read_file(project, long, "long.txt")
      assert truncated.truncated?
      assert length(String.split(truncated.content, "\n")) == 100
    end

    test "reads and redacts the README", %{project: project, clean: clean, secret: secret} do
      assert {:ok, readme} = Portfolio.read_readme(project, clean)
      assert readme.name == "README.md"
      assert readme.markdown =~ "# Hello"
      refute readme.redacted?

      assert {:ok, redacted} = Portfolio.read_readme(project, secret)
      assert redacted.redacted?
      assert redacted.markdown =~ "[REDACTED]"
    end

    test "returns not_found when there is no README", %{project: project} do
      node = insert_node_with_files(project, %{message: "no readme"}, %{"a.txt" => "a\n"})
      assert {:error, :not_found} = Portfolio.read_readme(project, node)
    end
  end

  describe "membership_for/2" do
    test "returns the membership or nil" do
      project = insert_project()
      user_id = Ecto.UUID.generate()

      %Membership{}
      |> Membership.changeset(%{
        user_id: user_id,
        project_id: project.id,
        role: :owner
      })
      |> Repo.insert!()

      assert %{user_id: ^user_id, project_id: project_id} =
               Portfolio.membership_for(user_id, project.id)

      assert project_id == project.id
      assert Portfolio.membership_for(Ecto.UUID.generate(), project.id) == nil
      assert Portfolio.membership_for("nope", project.id) == nil
    end
  end

  defp insert_project(slug \\ "demo") do
    %Project{}
    |> Project.changeset(%{
      name: "Demo",
      slug: slug,
      owner_id: Ecto.UUID.generate()
    })
    |> Repo.insert!()
  end

  defp insert_node_with_files(project, attrs, files) do
    commit = snapshot(project, files)

    attrs =
      Map.merge(
        %{
          project_id: project.id,
          git_commit_sha: commit,
          created_by: project.owner_id,
          created_at: DateTime.utc_now(),
          docs_state: :pending,
          flags: [:"in-progress"],
          message: "node"
        },
        attrs
      )

    %Node{}
    |> Node.changeset(attrs)
    |> Repo.insert!()
  end

  defp snapshot(project, files) do
    repo = ProjectGit.init(project.id)

    dir =
      Path.join(
        System.tmp_dir!(),
        "cadence_portfolio_snapshot_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    Enum.each(files, fn {path, content} ->
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end)

    tree = GitStore.build_tree(repo, dir)

    commit =
      GitStore.write_commit(
        repo,
        tree,
        [],
        %{name: "test", email: "test@example.com"},
        "snapshot"
      )

    File.rm_rf!(dir)
    commit
  end

  defp insert_node(project, attrs) do
    attrs =
      Map.merge(
        %{
          project_id: project.id,
          git_commit_sha: String.duplicate("a", 40),
          created_by: project.owner_id,
          created_at: DateTime.utc_now(),
          docs_state: :pending,
          flags: [:"in-progress"],
          message: "node"
        },
        attrs
      )

    %Node{}
    |> Node.changeset(attrs)
    |> Repo.insert!()
  end
end
