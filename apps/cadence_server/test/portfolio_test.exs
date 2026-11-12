defmodule Cadence.Server.PortfolioTest do
  use ExUnit.Case, async: false

  alias Cadence.Server.{Portfolio, ProjectGit, Repo}
  alias Cadence.Shared.{GitStore, Membership, Node, Project}

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  describe "list_projects/0" do
    test "lists projects newest first with node counts" do
      older = insert_project_with_created_at("older", ~U[2026-10-20 00:00:00Z])
      newer = insert_project_with_created_at("newer", ~U[2026-10-24 00:00:00Z])

      insert_node(older, %{message: "older node"})
      insert_node(newer, %{message: "newer one"})
      insert_node(newer, %{message: "newer two"})

      assert [
               %{project: %{id: newer_id}, node_count: 2},
               %{project: %{id: older_id}, node_count: 1}
             ] = Portfolio.list_projects()

      assert newer_id == newer.id
      assert older_id == older.id
    end

    test "returns an empty list when there are no projects" do
      assert Portfolio.list_projects() == []
    end
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

  describe "list_nodes/2" do
    test "limit and offset page through nodes in newest-first order" do
      project = insert_project()
      [newest, second, third, oldest] = Enum.reverse(insert_ordered_nodes(project, 4))

      assert ids(Portfolio.list_nodes(project.id, limit: 2)) == [newest.id, second.id]

      assert ids(Portfolio.list_nodes(project.id, limit: 2, offset: 1)) ==
               [second.id, third.id]

      assert ids(Portfolio.list_nodes(project.id, limit: 2, offset: 2)) ==
               [third.id, oldest.id]
    end

    test "limit without offset and offset without limit" do
      project = insert_project()
      nodes = insert_ordered_nodes(project, 3)

      # `list_nodes/1` keeps its no-limit behavior.
      assert ids(Portfolio.list_nodes(project.id)) == Enum.map(Enum.reverse(nodes), & &1.id)

      # An offset needs a page to offset within, so it is ignored alone.
      assert ids(Portfolio.list_nodes(project.id, offset: 1)) ==
               Enum.map(Enum.reverse(nodes), & &1.id)

      # Non-positive or non-integer bounds fall back to "no limit".
      assert ids(Portfolio.list_nodes(project.id, limit: 0)) ==
               Enum.map(Enum.reverse(nodes), & &1.id)

      assert ids(Portfolio.list_nodes(project.id, limit: -1)) ==
               Enum.map(Enum.reverse(nodes), & &1.id)

      assert ids(Portfolio.list_nodes(project.id, limit: nil)) ==
               Enum.map(Enum.reverse(nodes), & &1.id)
    end

    test "returns [] for an invalid project id even with paging" do
      assert Portfolio.list_nodes("not-a-uuid", limit: 2, offset: 1) == []
    end
  end

  describe "count_nodes/1" do
    test "counts only the project's nodes" do
      project = insert_project()
      other = insert_project("other")

      insert_ordered_nodes(project, 3)
      insert_node(other, %{message: "other"})

      assert Portfolio.count_nodes(project.id) == 3
      assert Portfolio.count_nodes(other.id) == 1
    end

    test "returns 0 for an empty, unknown, or invalid project" do
      empty = insert_project("empty")

      assert Portfolio.count_nodes(empty.id) == 0
      assert Portfolio.count_nodes(Ecto.UUID.generate()) == 0
      assert Portfolio.count_nodes("not-a-uuid") == 0
    end
  end

  describe "node_page/3" do
    test "an empty project is one empty page" do
      project = insert_project()

      assert %{
               nodes: [],
               offset: 0,
               limit: 50,
               page: 1,
               total: 0,
               total_pages: 1,
               has_prev: false,
               has_next: false
             } = Portfolio.node_page(project.id, 1)
    end

    test "exactly one page of 50 rows has no neighbour links" do
      project = insert_project()
      insert_ordered_nodes(project, 50)

      page = Portfolio.node_page(project.id, 1)

      assert page.total == 50
      assert page.total_pages == 1
      assert page.offset == 0
      assert length(page.nodes) == 50
      refute page.has_prev
      refute page.has_next
    end

    test "51 rows put the oldest alone on page 2" do
      project = insert_project()
      nodes = insert_ordered_nodes(project, 51)
      oldest = hd(nodes)
      newest = List.last(nodes)

      first = Portfolio.node_page(project.id, 1)
      second = Portfolio.node_page(project.id, 2)

      assert first.total_pages == 2
      assert length(first.nodes) == 50
      assert hd(first.nodes).id == newest.id
      refute Enum.any?(first.nodes, &(&1.id == oldest.id))
      assert first.has_next
      refute first.has_prev

      assert second.offset == 50
      assert ids(second.nodes) == [oldest.id]
      assert second.has_prev
      refute second.has_next
    end

    test "100 rows page 2 starts at offset 50 with 50 rows" do
      project = insert_project()
      insert_ordered_nodes(project, 100)

      page = Portfolio.node_page(project.id, 2)

      assert page.total == 100
      assert page.total_pages == 2
      assert page.offset == 50
      assert page.page == 2
      assert length(page.nodes) == 50
      assert page.has_prev
      refute page.has_next
    end

    test "junk, zero, and negative pages read page 1" do
      project = insert_project()
      nodes = insert_ordered_nodes(project, 51)
      newest = List.last(nodes)

      for page <- [0, -3, "abc", nil, 1.5] do
        page_data = Portfolio.node_page(project.id, page)

        assert page_data.page == 1
        assert page_data.offset == 0
        assert hd(page_data.nodes).id == newest.id
      end
    end

    test "an out-of-range page clamps to the last page" do
      project = insert_project()
      nodes = insert_ordered_nodes(project, 51)
      oldest = hd(nodes)

      page = Portfolio.node_page(project.id, 999)

      assert page.page == 2
      assert page.total_pages == 2
      assert page.offset == 50
      assert ids(page.nodes) == [oldest.id]
      refute page.has_next
    end

    test "an invalid project yields an empty page" do
      assert %{nodes: [], total: 0, total_pages: 1, page: 1, offset: 0} =
               Portfolio.node_page("not-a-uuid", 3)

      assert %{nodes: [], total: 0, total_pages: 1, page: 1, offset: 0} =
               Portfolio.node_page(Ecto.UUID.generate(), 1)
    end

    test "a custom size drives the page window and a bad size falls back" do
      project = insert_project()
      insert_ordered_nodes(project, 5)

      page = Portfolio.node_page(project.id, 3, 2)

      assert page.limit == 2
      assert page.total_pages == 3
      assert page.offset == 4
      assert length(page.nodes) == 1

      assert Portfolio.node_page(project.id, 1, 0).limit == 50
      assert Portfolio.node_page(project.id, 1, -5).limit == 50
      assert Portfolio.node_page(project.id, 1, "big").limit == 50
    end

    test "one count and one page read" do
      attach_node_query_counter()
      project = insert_project()
      insert_ordered_nodes(project, 3)

      # Drop the seeding inserts so the count measures only the read.
      _ = node_query_count()

      Portfolio.node_page(project.id, 1)

      assert node_query_count() == 2
    end
  end

  describe "history_page/2" do
    test "the newest node is on page 1" do
      project = insert_project()
      nodes = insert_ordered_nodes(project, 51)
      newest = List.last(nodes)

      assert Portfolio.history_page(project.id, newest) == 1
    end

    test "the oldest of 51 is on page 2" do
      project = insert_project()
      oldest = hd(insert_ordered_nodes(project, 51))

      assert Portfolio.history_page(project.id, oldest) == 2
    end

    test "the page boundary is exact" do
      project = insert_project()
      # Oldest first: node 20 sorts after 10 newer nodes, so with size 10 it is
      # the first row of page 2; node 21 has only 9 newer.
      nodes = insert_ordered_nodes(project, 30)
      node_20 = Enum.at(nodes, 19)
      node_21 = Enum.at(nodes, 20)

      assert Portfolio.history_page(project.id, node_20, 10) == 2
      assert Portfolio.history_page(project.id, node_21, 10) == 1
    end

    test "a created_at tie breaks by id descending" do
      project = insert_project()
      at = ~U[2026-10-24 12:00:00.000000Z]

      lower =
        insert_node(project, %{
          id: "00000000-0000-0000-0000-000000000001",
          message: "lower id",
          created_at: at
        })

      higher =
        insert_node(project, %{
          id: "00000000-0000-0000-0000-000000000002",
          message: "higher id",
          created_at: at
        })

      # The ordering is `created_at DESC, id DESC`, so the higher id sorts
      # first and the lower id has exactly one newer row.
      assert Portfolio.history_page(project.id, higher, 1) == 1
      assert Portfolio.history_page(project.id, lower, 1) == 2
    end

    test "returns nil without a usable project, node, or timestamp" do
      project = insert_project()
      node = insert_node(project, %{message: "node"})

      assert Portfolio.history_page("not-a-uuid", node) == nil
      assert Portfolio.history_page(project.id, nil) == nil
      assert Portfolio.history_page(project.id, %Node{id: Ecto.UUID.generate()}) == nil

      assert Portfolio.history_page(
               project.id,
               %Node{id: "not-a-uuid", created_at: ~U[2026-10-24 12:00:00Z]}
             ) == nil
    end

    test "one aggregate count, never a full load" do
      attach_node_query_counter()
      project = insert_project()
      nodes = insert_ordered_nodes(project, 3)

      _ = node_query_count()

      assert Portfolio.history_page(project.id, hd(nodes)) == 1
      assert node_query_count() == 1
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

    test "prefers the newest of two functioning nodes" do
      project = insert_project()

      insert_node(project, %{
        flags: [:functioning],
        message: "older functioning",
        created_at: ~U[2026-10-20 00:00:00Z]
      })

      newer =
        insert_node(project, %{
          flags: [:functioning],
          message: "newer functioning",
          created_at: ~U[2026-10-24 00:00:00Z]
        })

      assert Portfolio.preview_node(project.id).id == newer.id
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

    test "prefers the newest pinned node over an older pinned functioning node" do
      project = insert_project()

      insert_node(project, %{
        pinned: true,
        flags: [:functioning],
        message: "older pinned functioning",
        created_at: ~U[2026-10-20 00:00:00Z]
      })

      newer =
        insert_node(project, %{
          pinned: true,
          flags: [:"in-progress"],
          message: "newer pinned",
          created_at: ~U[2026-10-24 00:00:00Z]
        })

      assert Portfolio.preview_node(project.id).id == newer.id
    end

    test "prefers a pinned functioning node over a newer unpinned functioning node" do
      project = insert_project()

      pinned =
        insert_node(project, %{
          pinned: true,
          flags: [:functioning],
          message: "pinned functioning",
          created_at: ~U[2026-10-20 00:00:00Z]
        })

      insert_node(project, %{
        flags: [:functioning],
        message: "newer unpinned functioning",
        created_at: ~U[2026-10-24 00:00:00Z]
      })

      assert Portfolio.preview_node(project.id).id == pinned.id
    end

    test "returns nil for an invalid project id" do
      assert Portfolio.preview_node("not-a-uuid") == nil
    end

    test "resolves the precedence in exactly one nodes query" do
      attach_node_query_counter()
      project = insert_project()

      # No pinned and no functioning node: the old three-step resolver issued a
      # query per precedence step here, so a count of one pins the fold.
      insert_node(project, %{
        flags: [:"in-progress"],
        message: "older",
        created_at: ~U[2026-10-20 00:00:00Z]
      })

      insert_node(project, %{
        flags: [:broken],
        message: "middle",
        created_at: ~U[2026-10-22 00:00:00Z]
      })

      newest =
        insert_node(project, %{
          flags: [],
          message: "newest",
          created_at: ~U[2026-10-24 00:00:00Z]
        })

      # The seeding inserts emit node queries too; drop them so the count below
      # measures only the resolver.
      _ = node_query_count()

      assert %Node{id: id} = Portfolio.preview_node(project.id)
      assert id == newest.id
      assert node_query_count() == 1
    end
  end

  describe "docs_child/2" do
    test "finds the newest docs child linked by metadata and DAG parentage" do
      project = insert_project()
      code = insert_node(project, %{message: "code"})

      older =
        insert_node(project, %{
          message: "older docs",
          parents: [code.id],
          docs_state: :current,
          session_metadata: %{"docs" => %{"docs_for" => code.id}},
          created_at: ~U[2026-10-20 00:00:00Z]
        })

      newest =
        insert_node(project, %{
          message: "newest docs",
          parents: [code.id],
          docs_state: :current,
          session_metadata: %{"docs" => %{"docs_for" => code.id}},
          created_at: ~U[2026-10-24 00:00:00Z]
        })

      assert Portfolio.docs_child(project.id, code.id).id == newest.id
      refute Portfolio.docs_child(project.id, code.id).id == older.id
    end

    test "ignores metadata-only claims and malformed metadata" do
      project = insert_project()
      code = insert_node(project, %{message: "code"})

      # No DAG parentage: client-supplied metadata alone must not create a link.
      insert_node(project, %{
        message: "metadata only",
        docs_state: :current,
        session_metadata: %{"docs" => %{"docs_for" => code.id}}
      })

      # Parentage but a non-string docs_for, and a non-map docs value.
      insert_node(project, %{
        message: "bad id",
        parents: [code.id],
        session_metadata: %{"docs" => %{"docs_for" => 123}}
      })

      insert_node(project, %{
        message: "bad docs",
        parents: [code.id],
        session_metadata: %{"docs" => "nope"}
      })

      assert Portfolio.docs_child(project.id, code.id) == nil
    end

    test "is scoped to the project and handles invalid or nil ids" do
      project = insert_project()
      other = insert_project("other")
      code = insert_node(project, %{message: "code"})

      insert_node(other, %{
        message: "other docs",
        parents: [code.id],
        docs_state: :current,
        session_metadata: %{"docs" => %{"docs_for" => code.id}}
      })

      assert Portfolio.docs_child(project.id, code.id) == nil
      assert Portfolio.docs_child(project.id, nil) == nil
      assert Portfolio.docs_child("not-a-uuid", code.id) == nil
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

      # Callers that cache must distinguish a completed scan from a failure.
      assert Portfolio.quarantine_status_with_source(project, clean) == {:ok, :ok}
      assert Portfolio.quarantine_status_with_source(project, secret) == {:ok, :quarantined}

      assert Portfolio.quarantine_status_with_source(project, missing) ==
               {:error, :unverifiable}
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
    test "lists memberships for a project" do
      project = insert_project()
      owner_id = Ecto.UUID.generate()
      trusted_id = Ecto.UUID.generate()
      viewer_id = Ecto.UUID.generate()

      for {user_id, role} <- [
            {viewer_id, :viewer},
            {trusted_id, :trusted},
            {owner_id, :owner}
          ] do
        %Membership{}
        |> Membership.changeset(%{user_id: user_id, project_id: project.id, role: role})
        |> Repo.insert!()
      end

      assert Enum.map(Portfolio.list_memberships(project.id), &{&1.user_id, &1.role}) == [
               {owner_id, :owner},
               {trusted_id, :trusted},
               {viewer_id, :viewer}
             ]

      assert Portfolio.list_memberships("not-a-uuid") == []
    end

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

  # Counts statements against the `nodes` table. Ecto derives the event prefix
  # from the repo module name (not `otp_app`): `Cadence.Server.Repo` →
  # `[:cadence, :server, :repo, :query]`. Attached only by the query-count test
  # and detached on exit, so the handler never outlives that test.
  defp attach_node_query_counter do
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:cadence, :server, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:source] == "nodes" do
            send(test_pid, {:node_query, metadata.query})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # Queries run in the caller under the sandbox, so the handler has already run
  # and the message is in our own mailbox — `after 0` is enough.
  defp node_query_count(acc \\ 0) do
    receive do
      {:node_query, _query} -> node_query_count(acc + 1)
    after
      0 -> acc
    end
  end

  defp ids(nodes), do: Enum.map(nodes, & &1.id)

  # Oldest first, one minute apart, so ordering is independent of insert order.
  defp insert_ordered_nodes(project, count) do
    base = ~U[2026-10-24 12:00:00Z]

    Enum.map(1..count, fn index ->
      insert_node(project, %{
        message: "node #{index}",
        created_at: DateTime.add(base, index, :minute)
      })
    end)
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

  defp insert_project_with_created_at(slug, created_at) do
    %Project{}
    |> Project.changeset(%{
      name: String.capitalize(slug),
      slug: slug,
      owner_id: Ecto.UUID.generate(),
      created_at: created_at
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
