defmodule Cadence.Server.DemoSeed do
  @moduledoc """
  Builds the browsable demo dataset (spec §12.4).

  Three projects cover every surface the web UI has today:

  - `cadence-demo` — a DAG with functioning/broken/sandbox/in-progress nodes,
    a pinned node, a README, source files, and a secret-tainted snapshot that
    triggers the quarantine UI through an open critical node incident.
  - `meld-review` — two parents plus a pending meld, a pending promotion, an
    approved meld (created through `Proposals.approve/3` so its node comes from
    the real path), a rejected meld, and an isolated result carrying a critical
    `secret_detected` incident.
  - `imported-demo` — 160 nodes shaped exactly like a Git import (original
    40-hex SHAs, preserved parents including one merge, imported nodes,
    `docs_state: :skipped`, per-commit author/timestamp provenance). It
    deliberately exceeds the DAG render cap so the project page truncates and
    `History` pages, and one historical commit carries a high-confidence token,
    so the real push scan quarantines an imported snapshot.

  Four accounts share the demo password (spec §7.4 demo strategy): an owner, a
  trusted approver, a viewer, and an outsider with no membership.

  The seed is idempotent: when the demo projects already exist it returns the
  current summary and writes nothing. `reset: true` removes the demo projects,
  their rows and Git stores, and the demo users before rebuilding.

  This runs from `mix cadence.demo_seed` only; it is never an HTTP route.
  """

  import Ecto.Query

  alias Cadence.Server.{
    Accounts,
    ActionRun,
    Actions,
    Incidents,
    NodeScans,
    ProjectGit,
    Proposals,
    Repo
  }

  alias Cadence.Server.Accounts.{ApiKey, LocalAuth, Token, User, UserIdentity}
  alias Cadence.Server.Proposal
  alias Cadence.Server.Security.SecretBox
  alias Cadence.Shared.{GitStore, Membership, Node, Project}

  @password "cadence-demo"

  # Fixed 20-byte TOTP secret for every demo account (base32). It is public by
  # design: the demo is a local walkthrough, and `mix cadence.totp` prints the
  # current code. Production accounts always get a random secret.
  @demo_totp_secret Base.decode32!("JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP")

  @accounts [
    %{email: "owner@demo.local", name: "Demo Owner"},
    %{email: "approver@demo.local", name: "Demo Approver"},
    %{email: "viewer@demo.local", name: "Demo Viewer"},
    %{email: "outsider@demo.local", name: "Demo Outsider"}
  ]

  @demo_slug "cadence-demo"
  @review_slug "meld-review"
  @imported_slug "imported-demo"
  @slugs [@demo_slug, @review_slug, @imported_slug]

  # The imported project is deliberately larger than `CAD_DAG_MAX_NODES` (150)
  # and not an exact multiple of the History page size (50), so the demo shows
  # a truncation note and four pages where the last page is short.
  @imported_node_count 160
  @import_commit_interval 6 * 60 * 60
  # The secret-bearing commit sits among the ten oldest nodes, outside the
  # rendered DAG window, so the tour must use History to find it.
  @import_secret_commit 4
  @import_branch_point 98
  @import_merge_commit @import_branch_point + 3

  @import_authors [
    %{name: "Ada Lovelace", email: "ada.lovelace@example.com"},
    %{name: "Grace Hopper", email: "grace.hopper@example.com"},
    %{name: "Margaret Hamilton", email: "margaret.hamilton@example.com"},
    %{name: "Linus Torvalds", email: "linus.torvalds@example.com"}
  ]

  @import_verbs ~w(Refactor Document Fix Improve Simplify Extract Inline Rename Harden
                   Trim Split Add Tidy Cache Validate Guard)

  @import_objects [
    "the session watcher",
    "the DAG layout",
    "pack indexing",
    "the sync ledger",
    "quarantine checks",
    "the review queue",
    "CLI argument parsing",
    "the action runner",
    "history paging",
    "import provenance"
  ]

  @doc """
  Seeds the demo dataset and returns a summary map.

  Options:

  - `:reset` — delete the demo projects, their rows/stores, and the demo users
    first (default `false`).
  """
  @spec run(keyword()) :: map()
  def run(opts \\ []) do
    # Serialize seed/reset runs. `build!` cannot be one transaction because
    # `Proposals.approve/3` must run outside a caller-owned transaction, so a
    # session-level advisory lock on a checked-out connection is the fence
    # against two containers (or an `exec --reset` during boot) racing.
    Repo.checkout(fn ->
      Repo.query!("SELECT pg_advisory_lock(hashtext('cadence.demo_seed')::bigint)")

      try do
        do_run(opts)
      after
        Repo.query!("SELECT pg_advisory_unlock(hashtext('cadence.demo_seed')::bigint)")
      end
    end)
  end

  defp do_run(opts) do
    # A crashed first run can leave demo users or one project behind. Rebuild
    # from a clean slate instead of crashing on a slug/email unique constraint.
    reset? = Keyword.get(opts, :reset, false) or (not seeded?() and demo_rows?())
    if reset?, do: reset!()

    if seeded?() do
      summary(false)
    else
      build!()
      summary(true)
    end
  end

  @doc "Whether all demo projects already exist."
  @spec seeded?() :: boolean()
  def seeded? do
    count = Repo.aggregate(from(p in Project, where: p.slug in ^@slugs), :count)
    count == length(@slugs)
  end

  @doc "The shared demo password (public by design; demo builds only)."
  @spec password() :: String.t()
  def password, do: @password

  defp demo_rows? do
    Repo.exists?(from(p in Project, where: p.slug in ^@slugs)) or
      Repo.exists?(from(u in User, where: u.email in ^Enum.map(@accounts, & &1.email)))
  end

  defp build! do
    owner = upsert_user!("owner@demo.local")
    approver = upsert_user!("approver@demo.local")
    viewer = upsert_user!("viewer@demo.local")
    _outsider = upsert_user!("outsider@demo.local")

    demo = create_project!(%{name: "Cadence Demo", slug: @demo_slug, owner_id: owner.id})
    review = create_project!(%{name: "Meld Review", slug: @review_slug, owner_id: owner.id})
    imported = create_project!(%{name: "Imported Demo", slug: @imported_slug, owner_id: owner.id})

    add_membership!(demo, owner, :owner)
    add_membership!(demo, approver, :viewer)
    add_membership!(demo, viewer, :viewer)

    add_membership!(review, owner, :owner)
    add_membership!(review, approver, :trusted, approver: true)
    add_membership!(review, viewer, :viewer)

    add_membership!(imported, owner, :owner)

    seed_demo_project(demo, owner)
    seed_review_project(review, owner)
    seed_imported_project(imported, owner)

    :ok
  end

  # -- cadence-demo ---------------------------------------------------------

  defp seed_demo_project(project, owner) do
    base = DateTime.utc_now() |> DateTime.add(-3_600, :second)
    at = fn minutes -> DateTime.add(base, minutes, :second) end

    root =
      snapshot_node!(project, owner, demo_root_files(), %{
        message: "Initial import",
        flags: [:functioning],
        created_at: at.(0)
      })

    functioning =
      snapshot_node!(project, owner, demo_functioning_files(), %{
        message: "Add greeting helper",
        flags: [:functioning],
        pinned: true,
        parent_nodes: [root],
        created_at: at.(300)
      })

    _broken =
      snapshot_node!(project, owner, demo_broken_files(), %{
        message: "Refactor greeting (broken)",
        flags: [:broken],
        parent_nodes: [functioning],
        created_at: at.(600)
      })

    _sandbox =
      snapshot_node!(project, owner, demo_sandbox_files(), %{
        message: "Try a different layout",
        flags: [:sandbox],
        parent_nodes: [functioning],
        created_at: at.(900)
      })

    tainted =
      snapshot_node!(project, owner, demo_tainted_files(), %{
        message: "Wire up deployment config",
        flags: [:"in-progress"],
        parent_nodes: [functioning],
        created_at: at.(1_200)
      })

    {:ok, _incident} =
      Incidents.open(%{
        project_id: project.id,
        node_id: tainted.id,
        kind: :secret_detected,
        severity: :critical,
        title: "Potential secret in deployment config",
        details: %{stage: :push_scan, patterns: [:aws_access_key]}
      })

    seed_demo_run(project, owner, functioning, at)

    :ok
  end

  # One terminal run so the run history and detail pages are part of the demo
  # (and the visual pass). Nothing is executed: the row and its captured log are
  # written directly, best-effort (an unwritable artifact dir leaves
  # `log_path: nil` and the page shows "No output was captured").
  defp seed_demo_run(project, owner, node, at) do
    {:ok, run} =
      %ActionRun{}
      |> ActionRun.changeset(%{
        project_id: project.id,
        node_id: node.id,
        user_id: owner.id,
        action_name: "run_analysis",
        command: "python actions/run.py"
      })
      |> Repo.insert()

    log = """
    $ python actions/run.py
    cadence demo action
    greeting: Hello from the demo
    files: 3
    finished in 0.03s
    """

    log_path =
      case write_demo_log(run, log) do
        {:ok, path} -> path
        :error -> nil
      end

    started_at = at.(1_500)
    finished_at = DateTime.add(started_at, 3, :second)

    Repo.update_all(
      from(r in ActionRun, where: r.id == ^run.id),
      set: [
        status: :succeeded,
        exit_code: 0,
        image: "python:3.12-slim",
        log_path: log_path,
        created_at: started_at,
        started_at: started_at,
        finished_at: finished_at,
        updated_at: finished_at
      ]
    )

    :ok
  end

  defp write_demo_log(run, log) do
    relative = Path.join(run.id, "output.log")
    absolute = Path.join(Actions.artifact_path(), relative)

    with :ok <- File.mkdir_p(Path.dirname(absolute)),
         :ok <- File.write(absolute, log) do
      {:ok, relative}
    else
      _other -> :error
    end
  end

  defp demo_root_files do
    %{
      "README.md" => """
      # Cadence Demo

      A small project used to explore the Cadence web UI. Every snapshot here is
      a real Git tree stored by `Cadence.Shared.GitStore`.

      ## What to look at

      - The DAG on the project page: pinned, functioning, broken, sandbox and
        in-progress nodes.
      - The repository browser: a README, source files and nested folders.
      - The **Deployment config** node: it carries an open critical incident, so
        the public view is quarantined.

      ```elixir
      CadenceDemo.greet("world")
      ```
      """,
      "lib/cadence_demo.ex" => """
      defmodule CadenceDemo do
        @moduledoc \"\"\"
        Tiny module for the demo snapshots.
        \"\"\"

        @doc \"Greets someone.\"
        def greet(name), do: "Hello, \#{name}!"
      end
      """,
      "notes/architecture.md" => """
      # Notes

      The DAG is append-only. Each node is one immutable snapshot; branches are
      just nodes that share an ancestor.

      1. root
      2. functioning work
      3. a broken refactor
      4. a sandbox experiment
      5. deployment config (quarantined)
      """
    }
  end

  defp demo_functioning_files do
    Map.merge(demo_root_files(), %{
      "README.md" => """
      # Cadence Demo

      A small project used to explore the Cadence web UI.

      ## Latest change

      `CadenceDemo.greet/1` and `CadenceDemo.farewell/1` are available. This
      snapshot is pinned, so it is the project preview.
      """,
      "lib/cadence_demo.ex" => """
      defmodule CadenceDemo do
        @moduledoc \"\"\"
        Tiny module for the demo snapshots.
        \"\"\"

        @doc \"Greets someone.\"
        def greet(name), do: "Hello, \#{name}!"

        @doc \"Says goodbye.\"
        def farewell(name), do: "Goodbye, \#{name}."
      end
      """
    })
  end

  defp demo_broken_files do
    Map.merge(demo_functioning_files(), %{
      "README.md" => """
      # Cadence Demo

      This snapshot is marked **broken**: the refactor on this branch calls a
      helper that does not exist yet.
      """,
      "lib/cadence_demo.ex" => """
      defmodule CadenceDemo do
        @moduledoc \"\"\"
        Tiny module for the demo snapshots.
        \"\"\"

        # FIXME: greet_all/1 is not defined on this branch.
        def greet_everyone(names) do
          Enum.map(names, &greet_all/1)
        end

        def greet(name), do: "Hello, \#{name}!"
        def farewell(name), do: "Goodbye, \#{name}."
      end
      """
    })
  end

  defp demo_sandbox_files do
    Map.merge(demo_functioning_files(), %{
      "experiments/layout.md" => """
      # Layout experiment

      A sandbox branch for trying a two-column layout. Nothing here is
      promoted yet.
      """,
      "README.md" => """
      # Cadence Demo (sandbox)

      This branch carries a layout experiment. The functioning branch stays
      pinned.
      """
    })
  end

  defp demo_tainted_files do
    Map.merge(demo_broken_files(), %{
      "README.md" => """
      # Cadence Demo

      This snapshot wires up deployment configuration. The public view of this
      node is **quarantined** by an open critical incident, so the README and
      files are hidden until the incident is resolved.

      Owners and trusted members can use **Show raw content** to inspect it.
      """,
      "config/secrets.env" => """
      # Deliberately fake demo credentials.
      AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
      AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
      """,
      "deploy/README.md" => """
      # Deploy

      `mix release` then point `CAD_DATABASE_URL` at Postgres.

      Do not commit real credentials; this file exists only to demonstrate the
      quarantine flow.
      """
    })
  end

  # -- meld-review ----------------------------------------------------------

  defp seed_review_project(project, owner) do
    base = DateTime.utc_now() |> DateTime.add(-1_800, :second)
    at = fn minutes -> DateTime.add(base, minutes, :second) end

    node_a =
      snapshot_node!(project, owner, greeter_base_files(), %{
        message: "Greeter baseline",
        flags: [:functioning],
        created_at: at.(0)
      })

    node_b =
      snapshot_node!(project, owner, greeter_branch_b_files(), %{
        message: "Add farewell and friendlier tone",
        flags: [:functioning],
        parent_nodes: [node_a],
        created_at: at.(120)
      })

    node_c =
      snapshot_node!(project, owner, greeter_branch_c_files(), %{
        message: "Add shout and playful tone",
        flags: [:"in-progress"],
        parent_nodes: [node_a],
        created_at: at.(240)
      })

    pending =
      create_meld!(
        project,
        owner,
        [node_b, node_c],
        greeter_merged_files("friendly (resolved)"),
        %{
          "demo" => "pending_meld"
        }
      )

    approved_result =
      write_result!(project, owner, [node_a, node_b], greeter_merged_files("friendly"))

    approved_proposal =
      create_proposal!(project, owner, %{
        kind: :meld,
        parent_ids: [node_a.id, node_b.id],
        result_tree_sha: approved_result.tree,
        meld_commit_sha: approved_result.commit
      })

    tag_proposal!(approved_proposal, %{"demo" => "approved_meld"})

    {:ok, _approved} = Proposals.approve(%{id: owner.id}, project.id, approved_proposal.id)

    rejected =
      create_meld!(project, owner, [node_a, node_c], greeter_merged_files("playful"), %{
        "demo" => "rejected_meld"
      })

    {:ok, _rejected} = Proposals.reject(%{id: owner.id}, project.id, rejected.id)

    _promotion =
      create_proposal!(project, owner, %{kind: :promotion, target_node_id: node_b.id})
      |> tag_proposal!(%{"demo" => "promotion"})

    isolated =
      create_meld!(project, owner, [node_b, node_c], greeter_merged_files("isolated"), %{
        "demo" => "isolated_meld"
      })

    {:ok, _incident} =
      Incidents.open(%{
        project_id: project.id,
        proposal_id: isolated.id,
        kind: :secret_detected,
        severity: :critical,
        title: "Potential secret in meld result",
        details: %{stage: :meld_creation, patterns: [:aws_access_key]}
      })

    _ = pending
    :ok
  end

  defp greeter_base_files do
    %{
      "README.md" => """
      # Meld Review

      Two branches of a tiny greeter, plus proposals in every review state.
      """,
      "lib/greeter.ex" => """
      defmodule Greeter do
        @moduledoc \"A tiny greeting module.\"

        @doc \"Says hello.\"
        def hello(name), do: "Hello, \#{name}."
      end
      """,
      "shared/tone.txt" => "formal\n"
    }
  end

  defp greeter_branch_b_files do
    Map.merge(greeter_base_files(), %{
      "lib/greeter.ex" => """
      defmodule Greeter do
        @moduledoc \"A tiny greeting module.\"

        @doc \"Says hello.\"
        def hello(name), do: "Hello, \#{name}."

        @doc \"Says goodbye.\"
        def goodbye(name), do: "Goodbye, \#{name}."
      end
      """,
      "shared/tone.txt" => "friendly\n",
      "README.md" => """
      # Meld Review

      Branch B adds a farewell and a friendlier tone.
      """
    })
  end

  defp greeter_branch_c_files do
    Map.merge(greeter_base_files(), %{
      "lib/greeter.ex" => """
      defmodule Greeter do
        @moduledoc \"A tiny greeting module.\"

        @doc \"Says hello.\"
        def hello(name), do: "Hello, \#{name}."

        @doc \"Shouts a greeting.\"
        def shout(name), do: String.upcase("Hello, \#{name}!")
      end
      """,
      "shared/tone.txt" => "playful\n",
      "README.md" => """
      # Meld Review

      Branch C adds a shout and a playful tone.
      """
    })
  end

  defp greeter_merged_files(tone) do
    %{
      "README.md" => """
      # Meld Review

      This result merges branches B and C. The conflicting `shared/tone.txt` was
      resolved by the reviewer.
      """,
      "lib/greeter.ex" => """
      defmodule Greeter do
        @moduledoc \"A tiny greeting module.\"

        @doc \"Says hello.\"
        def hello(name), do: "Hello, \#{name}."

        @doc \"Says goodbye.\"
        def goodbye(name), do: "Goodbye, \#{name}."

        @doc \"Shouts a greeting.\"
        def shout(name), do: String.upcase("Hello, \#{name}!")
      end
      """,
      "shared/tone.txt" => tone <> "\n"
    }
  end

  # -- imported-demo --------------------------------------------------------

  # This project exists to demonstrate Phase 9 in the browser without a daemon:
  # the rows have the exact shape `Cadence.Daemon.Importer` produces, the commit
  # objects are real Git commits (written through GitStore, never by shelling
  # out), and the one secret-bearing commit is passed through the same
  # `NodeScans` path a pushed node takes.
  defp seed_imported_project(project, owner) do
    repo = ProjectGit.init(project.id)
    {:ok, shared_tree} = GitStore.put_files(repo, imported_files())
    {:ok, secret_tree} = GitStore.put_files(repo, imported_secret_files())

    imported_at = DateTime.utc_now() |> DateTime.to_iso8601()
    base_unix = import_base_unix()

    nodes =
      Repo.transaction(fn ->
        0..(@imported_node_count - 1)
        |> Enum.reduce(%{}, fn index, acc ->
          parent_indexes = import_parent_indexes(index)

          parents =
            Enum.map(parent_indexes, fn parent_index ->
              Map.fetch!(acc, parent_index)
            end)

          author = Enum.at(@import_authors, rem(index, length(@import_authors)))
          timestamp = base_unix + index * @import_commit_interval
          tree = if index == @import_secret_commit, do: secret_tree, else: shared_tree
          message = import_message(index)

          sha =
            write_import_commit!(
              repo,
              tree,
              Enum.map(parents, & &1.git_commit_sha),
              author,
              timestamp,
              message
            )

          node =
            insert_imported_node!(project, owner, %{
              index: index,
              git_commit_sha: sha,
              parents: parents,
              author: author,
              timestamp: timestamp,
              message: message,
              imported_at: imported_at
            })

          Map.put(acc, index, node)
        end)
        |> then(fn by_index ->
          Enum.map(0..(@imported_node_count - 1), &Map.fetch!(by_index, &1))
        end)
      end)
      |> case do
        {:ok, nodes} -> nodes
        {:error, reason} -> raise "imported demo seed failed: #{inspect(reason)}"
      end

    # The real scan, not a hand-written incident: a `config.txt` carrying a
    # ghp-style token must quarantine exactly like a pushed snapshot would.
    :ok = NodeScans.scan_node(project.id, Enum.at(nodes, @import_secret_commit))

    :ok
  end

  # 0..98 linear, 99 and 100 branch from 98, 101 merges them, then linear to
  # the tip. Parents are preserved in commit order, like a real import.
  defp import_parent_indexes(0), do: []

  defp import_parent_indexes(index)
       when index in [@import_branch_point + 1, @import_branch_point + 2],
       do: [@import_branch_point]

  defp import_parent_indexes(@import_merge_commit),
    do: [@import_branch_point + 1, @import_branch_point + 2]

  defp import_parent_indexes(index), do: [index - 1]

  defp import_base_unix do
    DateTime.utc_now()
    |> DateTime.add(-@imported_node_count * @import_commit_interval, :second)
    |> DateTime.to_unix()
  end

  # `GitStore.write_commit/5` stamps "now"; an imported history needs the
  # original author timestamps, so encode the commit payload exactly like a
  # source repository would and write it through the shared raw primitive.
  defp write_import_commit!(repo, tree, parents, author, timestamp, message) do
    ident = "#{author.name} <#{author.email}> #{timestamp} +0000"

    [
      "tree #{tree}\n",
      Enum.map(parents, &"parent #{&1}\n"),
      "author #{ident}\n",
      "committer #{ident}\n",
      "\n",
      message,
      "\n"
    ]
    |> IO.iodata_to_binary()
    |> then(&GitStore.write_raw(repo, :commit, &1))
  end

  defp insert_imported_node!(project, owner, attrs) do
    tip? = attrs.index == @imported_node_count - 1

    node_attrs = %{
      project_id: project.id,
      git_commit_sha: attrs.git_commit_sha,
      parents: Enum.map(attrs.parents, & &1.id),
      flags: [:imported],
      pinned: tip?,
      message: attrs.message,
      session_metadata: import_metadata(attrs, tip?),
      created_by: owner.id,
      created_at: DateTime.from_unix!(attrs.timestamp, :second),
      docs_state: :skipped
    }

    case %Node{} |> Node.changeset(node_attrs) |> Repo.insert() do
      {:ok, node} -> node
      {:error, changeset} -> Repo.rollback({:invalid_import_node, changeset})
    end
  end

  defp import_metadata(attrs, tip?) do
    import = %{
      "source" => "git",
      "author" => attrs.author.name,
      "author_email" => attrs.author.email,
      "imported_at" => attrs.imported_at
    }

    # Matches the importer: selected refs are recorded on tip nodes only.
    import = if tip?, do: Map.put(import, "refs", ["refs/heads/main"]), else: import
    %{"import" => import}
  end

  defp import_message(index) do
    cond do
      index == 0 ->
        "Initial import of the cadence-cli repository"

      index == @import_secret_commit ->
        "Add deployment config for CI"

      index == @import_branch_point + 1 ->
        "Start the import UI branch"

      index == @import_branch_point + 2 ->
        "Add provenance rendering on the import branch"

      index == @import_merge_commit ->
        "Merge branch 'feature/import-ui' into main"

      true ->
        verb = Enum.at(@import_verbs, rem(index, length(@import_verbs)))
        object = Enum.at(@import_objects, div(index, length(@import_verbs)))
        "#{verb} #{object}"
    end
  end

  defp imported_files do
    %{
      "README.md" => """
      # Imported Demo

      This project is shaped like a local Git repository imported into Cadence:
      every node keeps its original 40-character commit SHA, parents, message,
      author and timestamp. The nodes carry the imported flag, docs are skipped
      (there is no local session to generate them), and only the tip is pinned.

      The project has 160 commits, so the DAG renders the newest 150 and the
      rest live in **History** (50 per page). One old commit contains a fake
      token and is quarantined by the same scan a push uses.
      """,
      "src/cadence_cli.ex" => """
      defmodule CadenceCLI do
        @moduledoc "A tiny stand-in module for the imported history."

        @doc "Prints the project greeting."
        def greet(name), do: "Hello from the import, \#{name}."
      end
      """,
      "docs/history.md" => """
      # Imported history

      Commits are copied byte-identically. Cadence never rewrites the source
      history, so the SHA in this project matches the SHA in the Git repository.
      """,
      "config/settings.toml" => """
      [project]
      name = "cadence-cli"
      default_branch = "main"
      """
    }
  end

  defp imported_secret_files do
    Map.put(imported_files(), "config.txt", """
    # Deliberately fake demo credentials.
    GITHUB_TOKEN=ghp_demo000000000000000000000000000000
    """)
  end

  # -- persistence helpers --------------------------------------------------

  defp upsert_user!(email) do
    case Repo.get_by(User, email: email) do
      nil ->
        %{name: name} = Enum.find(@accounts, &(&1.email == email))

        {:ok, user} =
          User
          |> Ash.Changeset.for_create(:create, %{
            email: email,
            name: name,
            hashed_password: LocalAuth.hash_password(@password),
            totp_secret: SecretBox.encrypt(@demo_totp_secret),
            totp_confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second),
            totp_last_used_at: nil
          })
          |> Ash.create(domain: Accounts)

        user

      user ->
        # A rerun after the auth rebuild must leave the demo walkable: refresh
        # the Argon2 hash and the deterministic TOTP secret, but never touch a
        # real (non-demo) account.
        {:ok, user} =
          user
          |> Ash.Changeset.for_update(:set_password, %{
            hashed_password: LocalAuth.hash_password(@password)
          })
          |> Ash.update(domain: Accounts)

        {:ok, user} =
          user
          |> Ash.Changeset.for_update(:confirm_totp, %{
            totp_secret: SecretBox.encrypt(@demo_totp_secret),
            totp_confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second),
            totp_last_used_at: nil
          })
          |> Ash.update(domain: Accounts)

        user
    end
  end

  defp create_project!(attrs) do
    # Get-or-create keeps a partial rerun from crashing on the slug unique
    # index; the advisory lock makes the check-then-insert safe.
    case Repo.get_by(Project, slug: attrs.slug) do
      nil ->
        {:ok, project} = %Project{} |> Project.changeset(attrs) |> Repo.insert()
        project

      project ->
        project
    end
  end

  defp add_membership!(project, user, role, extra \\ []) do
    attrs = Map.merge(%{user_id: user.id, project_id: project.id, role: role}, Map.new(extra))

    {:ok, _membership} = %Membership{} |> Membership.changeset(attrs) |> Repo.insert()
    :ok
  end

  defp snapshot_node!(project, author, files, attrs) do
    parents = Map.get(attrs, :parent_nodes, [])

    {:ok, tree} = GitStore.put_files(ProjectGit.init(project.id), files)

    sha =
      GitStore.write_commit(
        ProjectGit.open(project.id),
        tree,
        Enum.map(parents, & &1.git_commit_sha),
        author_identity(author),
        attrs.message
      )

    node_attrs = %{
      project_id: project.id,
      git_commit_sha: sha,
      parents: Enum.map(parents, & &1.id),
      flags: Map.get(attrs, :flags, [:"in-progress"]),
      pinned: Map.get(attrs, :pinned, false),
      message: attrs.message,
      created_by: author.id,
      created_at: Map.get(attrs, :created_at) || DateTime.utc_now(),
      docs_state: :pending
    }

    {:ok, node} = %Node{} |> Node.changeset(node_attrs) |> Repo.insert()
    node
  end

  defp create_meld!(project, author, parents, files, metadata) do
    result = write_result!(project, author, parents, files)

    proposal =
      create_proposal!(project, author, %{
        kind: :meld,
        parent_ids: Enum.map(parents, & &1.id),
        result_tree_sha: result.tree,
        meld_commit_sha: result.commit
      })

    tag_proposal!(proposal, metadata)
  end

  defp write_result!(project, author, parents, files) do
    {:ok, tree} = GitStore.put_files(ProjectGit.init(project.id), files)

    commit =
      GitStore.write_commit(
        ProjectGit.open(project.id),
        tree,
        Enum.map(parents, & &1.git_commit_sha),
        author_identity(author),
        "Meld result"
      )

    %{tree: tree, commit: commit}
  end

  defp create_proposal!(project, author, attrs) do
    {:ok, proposal} = Proposals.create(%{id: author.id}, Map.put(attrs, :project_id, project.id))
    proposal
  end

  # `result_metadata` is server-owned; the demo tags each proposal so the
  # summary can name tokens without guessing from kind/status (two proposals
  # can be pending melds).
  defp tag_proposal!(proposal, metadata) do
    {:ok, tagged} =
      proposal
      |> Ecto.Changeset.change(result_metadata: metadata)
      |> Repo.update()

    tagged
  end

  defp author_identity(user) do
    %{name: user.name || "Cadence Demo", email: user.email}
  end

  # -- summary / reset ------------------------------------------------------

  defp summary(fresh?) do
    projects =
      Repo.all(from(p in Project, where: p.slug in ^@slugs, order_by: [asc: p.slug]))

    users =
      Repo.all(from(u in User, where: u.email in ^Enum.map(@accounts, & &1.email)))

    tokens =
      case Enum.find(projects, &(&1.slug == @review_slug)) do
        nil ->
          %{}

        review ->
          review.id
          |> proposals_for_project()
          |> Enum.reduce(%{}, fn proposal, acc ->
            case proposal.result_metadata do
              %{"demo" => label} -> Map.put(acc, label, proposal.token)
              _other -> acc
            end
          end)
      end

    %{
      fresh: fresh?,
      password: @password,
      users: Enum.map(users, &%{email: to_string(&1.email), name: &1.name}),
      projects:
        Enum.map(projects, fn project ->
          %{
            slug: project.slug,
            name: project.name,
            url: "/p/#{project.slug}"
          }
        end),
      tokens: tokens,
      public_url: Application.get_env(:cadence_server, :public_url)
    }
  end

  defp proposals_for_project(project_id) do
    Repo.all(
      from(p in Proposal,
        where: p.project_id == ^project_id,
        order_by: [asc: p.created_at, asc: p.id]
      )
    )
  end

  defp reset! do
    {project_ids, run_ids} =
      Repo.transaction(fn ->
        project_ids = Repo.all(from(p in Project, where: p.slug in ^@slugs, select: p.id))

        run_ids =
          Repo.all(from(r in ActionRun, where: r.project_id in ^project_ids, select: r.id))

        Repo.delete_all(from(r in ActionRun, where: r.project_id in ^project_ids))
        Repo.delete_all(from(i in Cadence.Server.Incident, where: i.project_id in ^project_ids))
        Repo.delete_all(from(p in Proposal, where: p.project_id in ^project_ids))
        Repo.delete_all(from(n in Node, where: n.project_id in ^project_ids))
        Repo.delete_all(from(m in Membership, where: m.project_id in ^project_ids))
        Repo.delete_all(from(p in Project, where: p.id in ^project_ids))

        users =
          Repo.all(from(u in User, where: u.email in ^Enum.map(@accounts, & &1.email)))

        user_ids = Enum.map(users, & &1.id)
        # AshAuthentication subjects look like "user?id=<uuid>", not the bare
        # UUID; using the encoder keeps this in step with the library.
        subjects = Enum.map(users, &AshAuthentication.user_to_subject/1)

        Repo.delete_all(from(t in Token, where: t.subject in ^subjects))
        Repo.delete_all(from(i in UserIdentity, where: i.user_id in ^user_ids))
        Repo.delete_all(from(k in ApiKey, where: k.user_id in ^user_ids))
        Repo.delete_all(from(m in Membership, where: m.user_id in ^user_ids))
        Repo.delete_all(from(u in User, where: u.id in ^user_ids))

        {project_ids, run_ids}
      end)
      |> case do
        {:ok, result} -> result
        {:error, reason} -> raise "demo reset failed: #{inspect(reason)}"
      end

    Enum.each(project_ids, &File.rm_rf(ProjectGit.path(&1)))
    Enum.each(run_ids, &File.rm_rf(Path.join(Actions.artifact_path(), &1)))

    :ok
  end
end
