defmodule Cadence.Server.DemoSeed do
  @moduledoc """
  Builds the browsable demo dataset (spec §12.4).

  Two projects cover every surface the web UI has today:

  - `cadence-demo` — a DAG with functioning/broken/sandbox/in-progress nodes,
    a pinned node, a README, source files, and a secret-tainted snapshot that
    triggers the quarantine UI through an open critical node incident.
  - `meld-review` — two parents plus a pending meld, a pending promotion, an
    approved meld (created through `Proposals.approve/3` so its node comes from
    the real path), a rejected meld, and an isolated result carrying a critical
    `secret_detected` incident.

  Four accounts share the demo password (spec §7.4 demo strategy): an owner, a
  trusted approver, a viewer, and an outsider with no membership.

  The seed is idempotent: when the demo projects already exist it returns the
  current summary and writes nothing. `reset: true` removes the demo projects,
  their rows and Git stores, and the demo users before rebuilding.

  This runs from `mix cadence.demo_seed` only; it is never an HTTP route.
  """

  import Ecto.Query

  alias Cadence.Server.{Accounts, ActionRun, Actions, Incidents, ProjectGit, Proposals, Repo}
  alias Cadence.Server.Accounts.{ApiKey, Token, User, UserIdentity}
  alias Cadence.Server.Proposal
  alias Cadence.Shared.{GitStore, Membership, Node, Project}

  @password "cadence-demo"

  @accounts [
    %{email: "owner@demo.local", name: "Demo Owner"},
    %{email: "approver@demo.local", name: "Demo Approver"},
    %{email: "viewer@demo.local", name: "Demo Viewer"},
    %{email: "outsider@demo.local", name: "Demo Outsider"}
  ]

  @demo_slug "cadence-demo"
  @review_slug "meld-review"
  @slugs [@demo_slug, @review_slug]

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

  @doc "Whether both demo projects already exist."
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

    add_membership!(demo, owner, :owner)
    add_membership!(demo, approver, :viewer)
    add_membership!(demo, viewer, :viewer)

    add_membership!(review, owner, :owner)
    add_membership!(review, approver, :trusted, approver: true)
    add_membership!(review, viewer, :viewer)

    seed_demo_project(demo, owner)
    seed_review_project(review, owner)

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
            hashed_password: Bcrypt.hash_pwd_salt(@password)
          })
          |> Ash.create(domain: Accounts)

        user

      user ->
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
