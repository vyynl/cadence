defmodule Cadence.Server.Portfolio do
  @moduledoc """
  Read-only queries for the public project pages and repository browser.

  Public pages may browse any node's snapshot (spec §7.1), subject to the
  server-side filtering and quarantine in `Cadence.Server.PublicContent`.
  """

  import Ecto.Query

  alias Cadence.Server.{Incidents, ProjectGit, PublicContent, Repo}
  alias Cadence.Shared.{GitStore, Membership, Node, Project, UUID}

  @doc "Fetch a project by its URL slug."
  @spec get_project_by_slug(String.t()) :: {:ok, Project.t()} | {:error, :not_found}
  def get_project_by_slug(slug) when is_binary(slug) do
    case Repo.get_by(Project, slug: slug) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  def get_project_by_slug(_slug), do: {:error, :not_found}

  @doc """
  Fetch a project by its ID.

  Invalid UUID input returns `{:error, :not_found}` without touching the
  database, so public callers can treat bad input as a missing page.
  """
  @spec get_project(Ecto.UUID.t() | String.t() | nil) ::
          {:ok, Project.t()} | {:error, :not_found}
  def get_project(id) do
    case UUID.cast(id) do
      {:ok, project_id} ->
        case Repo.get(Project, project_id) do
          nil -> {:error, :not_found}
          project -> {:ok, project}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Fetch a node only if it belongs to the project.

  Returns `nil` for an unknown/invalid node or project ID.
  """
  @spec node_for_project(Ecto.UUID.t() | String.t(), Ecto.UUID.t() | String.t()) ::
          Node.t() | nil
  def node_for_project(project_id, node_id) do
    with {:ok, project_id} <- UUID.cast(project_id),
         {:ok, node_id} <- UUID.cast(node_id) do
      Repo.get_by(Node, id: node_id, project_id: project_id)
    else
      :error -> nil
    end
  end

  @doc """
  Fetch the newest docs child for a code node, if one exists (spec §9.5).

  A node pushed before its docs resolved keeps its immutable snapshot; the
  generation is attached as a child that records
  `session_metadata["docs"]["docs_for"]` and has the code node as a DAG parent.
  Both conditions are required so client-supplied metadata alone cannot claim a
  child link. Returns `nil` for unknown/invalid IDs or malformed metadata.
  """
  @spec docs_child(Ecto.UUID.t() | String.t(), Ecto.UUID.t() | String.t()) :: Node.t() | nil
  def docs_child(project_id, code_node_id) do
    with {:ok, project_id} <- UUID.cast(project_id),
         {:ok, code_node_id} <- UUID.cast(code_node_id) do
      Repo.one(
        from(n in Node,
          where: n.project_id == ^project_id,
          where: n.id != ^code_node_id,
          where: fragment("?->'docs'->>'docs_for' = ?", n.session_metadata, ^code_node_id),
          where: fragment("? = ANY(?)", type(^code_node_id, Ecto.UUID), n.parents),
          order_by: [desc: n.created_at, desc: n.id],
          limit: 1
        )
      )
    else
      :error -> nil
    end
  end

  @doc """
  List public projects for the portfolio index, newest first.

  Returns `%{project: Project.t(), node_count: non_neg_integer(), imported?: boolean()}`
  entries. `imported?` is true when any node carries the `:imported` flag.
  """
  @spec list_projects() :: [
          %{
            project: Project.t(),
            node_count: non_neg_integer(),
            imported?: boolean()
          }
        ]
  def list_projects do
    projects =
      Repo.all(
        from(p in Project,
          order_by: [desc: p.created_at, desc: p.id]
        )
      )

    counts =
      Repo.all(
        from(n in Node,
          group_by: n.project_id,
          select: {n.project_id, count(n.id)}
        )
      )
      |> Map.new()

    imported =
      Repo.all(
        from(n in Node,
          where: fragment("? = ANY(?)", "imported", n.flags),
          group_by: n.project_id,
          select: n.project_id
        )
      )
      |> MapSet.new()

    Enum.map(projects, fn project ->
      %{
        project: project,
        node_count: Map.get(counts, project.id, 0),
        imported?: MapSet.member?(imported, project.id)
      }
    end)
  end

  @doc "Whether any node in the project carries the `:imported` provenance flag."
  @spec imported?(Ecto.UUID.t()) :: boolean()
  def imported?(project_id) do
    Repo.exists?(
      from(n in Node,
        where: n.project_id == ^project_id,
        where: fragment("? = ANY(?)", "imported", n.flags)
      )
    )
  end

  @doc """
  List a project's nodes, newest first with a deterministic tie-break.

  Used by the public DAG. Options:

    * `:limit` — a positive integer caps the result; anything else (missing,
      non-integer, zero, or negative) means no limit.
    * `:offset` — a positive integer skips that many rows. It is only applied
      together with a limit: an offset without a limit is ignored, because
      there is no page to offset within.

  Returns `[]` for an unknown or invalid project.
  """
  @spec list_nodes(Ecto.UUID.t() | String.t(), keyword()) :: [Node.t()]
  def list_nodes(project_id, opts \\ []) do
    with {:ok, project_id} <- UUID.cast(project_id) do
      Repo.all(page_query(ordered_nodes(project_id), opts))
    else
      :error -> []
    end
  end

  @doc """
  Count a project's nodes.

  One aggregate query; an unknown or invalid project has zero nodes.
  """
  @spec count_nodes(Ecto.UUID.t() | String.t()) :: non_neg_integer()
  def count_nodes(project_id) do
    with {:ok, project_id} <- UUID.cast(project_id) do
      Repo.one(
        from(n in Node,
          where: n.project_id == ^project_id,
          select: count(n.id)
        )
      )
    else
      :error -> 0
    end
  end

  @doc """
  Default page size for the public commit history (spec §7.3).

  The History LiveView derives its page number from this value, so the page
  size and the context default cannot drift apart.
  """
  @spec node_page_size() :: pos_integer()
  def node_page_size, do: 50

  @doc """
  One page of a project's nodes, newest first (spec §7.3).

  The DAG window and the History list share the ordering in
  `ordered_nodes/1` (`created_at DESC, id DESC`), so pages are stable for a
  given set of rows.

  `page` is clamped into `1..total_pages` **before** the offset is computed, so
  a hand-edited `?page=` can never produce an out-of-range Postgres bind; a
  non-integer or non-positive value means page 1. `size` falls back to
  `node_page_size/0` when it is not a positive integer.

  Returns a page map; an unknown or invalid project yields an empty page with
  `total: 0` and `total_pages: 1`.
  """
  @spec node_page(Ecto.UUID.t() | String.t(), term(), term()) :: %{
          nodes: [Node.t()],
          offset: non_neg_integer(),
          limit: pos_integer(),
          page: pos_integer(),
          total: non_neg_integer(),
          total_pages: pos_integer(),
          has_prev: boolean(),
          has_next: boolean()
        }
  def node_page(project_id, page, size \\ node_page_size()) do
    size = page_size(size)

    with {:ok, project_id} <- UUID.cast(project_id) do
      total = count_nodes(project_id)
      total_pages = max(ceil_div(total, size), 1)
      page = clamp_page(page, total_pages)
      offset = (page - 1) * size

      nodes =
        Repo.all(
          page_query(ordered_nodes(project_id),
            limit: size,
            offset: offset
          )
        )

      %{
        nodes: nodes,
        offset: offset,
        limit: size,
        page: page,
        total: total,
        total_pages: total_pages,
        has_prev: page > 1,
        has_next: page < total_pages
      }
    else
      :error -> empty_node_page(size)
    end
  end

  @doc """
  The 1-based History page that contains `node`, in the newest-first order.

  One aggregate counts the nodes that sort before `node` — newer
  `created_at`, or the same timestamp with a larger id (the ordering's
  descending tie-break) — so no window of rows has to be loaded. Returns `nil`
  for an invalid project id, an unknown node shape, or a node without
  `created_at`.
  """
  @spec history_page(Ecto.UUID.t() | String.t(), Node.t() | nil, term()) ::
          pos_integer() | nil
  def history_page(project_id, node, size \\ node_page_size())

  def history_page(project_id, %Node{id: id, created_at: %DateTime{} = created_at}, size)
      when is_binary(id) do
    size = page_size(size)

    with {:ok, project_id} <- UUID.cast(project_id),
         {:ok, node_id} <- UUID.cast(id) do
      newer =
        Repo.one(
          from(n in Node,
            where: n.project_id == ^project_id,
            where:
              n.created_at > ^created_at or
                (n.created_at == ^created_at and n.id > ^node_id),
            select: count(n.id)
          )
        )

      div(newer, size) + 1
    else
      :error -> nil
    end
  end

  def history_page(_project_id, _node, _size), do: nil

  @doc """
  Resolve the preview node (spec §4.4): pinned, then functioning, then newest.

  Precedence is a three-tier `ORDER BY` expression — the pinned tier, then the
  functioning tier, then everything else — with `created_at DESC, id DESC` as
  the recency tie-break inside each tier, so one `LIMIT 1` statement resolves
  it. Returns `nil` for an unknown/invalid project.
  """
  @spec preview_node(Ecto.UUID.t() | String.t()) :: Node.t() | nil
  def preview_node(project_id) do
    with {:ok, project_id} <- UUID.cast(project_id) do
      Repo.one(
        from(n in Node,
          where: n.project_id == ^project_id,
          order_by: [
            asc:
              fragment(
                "CASE WHEN ? THEN 0 WHEN ? THEN 1 ELSE 2 END",
                n.pinned,
                # The dumped value of `:functioning`; keep in step with
                # `Cadence.Shared.Node.flags/0`.
                fragment("? = ANY(?)", "functioning", n.flags)
              ),
            desc: n.created_at,
            desc: n.id
          ],
          limit: 1
        )
      )
    else
      :error -> nil
    end
  end

  @doc "Fetch a user's membership in a project, or `nil`."
  @spec membership_for(Ecto.UUID.t() | String.t(), Ecto.UUID.t() | String.t()) ::
          Membership.t() | nil
  def membership_for(user_id, project_id) do
    with {:ok, user_id} <- UUID.cast(user_id),
         {:ok, project_id} <- UUID.cast(project_id) do
      Repo.get_by(Membership, user_id: user_id, project_id: project_id)
    else
      :error -> nil
    end
  end

  @doc "List a project's memberships for the member read view."
  @spec list_memberships(Ecto.UUID.t() | String.t()) :: [Membership.t()]
  def list_memberships(project_id) do
    with {:ok, project_id} <- UUID.cast(project_id) do
      Repo.all(
        from(m in Membership,
          where: m.project_id == ^project_id,
          order_by: [asc: m.role, asc: m.user_id]
        )
      )
    else
      :error -> []
    end
  end

  @readme_names [
    "README.md",
    "README.markdown",
    "README",
    "readme.md",
    "readme.markdown",
    "readme",
    "ReadMe.md",
    "ReadMe.markdown",
    "README.txt"
  ]

  @doc """
  Return `:quarantined` when the node's public snapshot must be hidden.

  An open critical node incident isolates the snapshot first (spec §6.7), so
  isolation persists until the incident is resolved. Otherwise a snapshot is
  quarantined when a high-confidence secret or non-example sensitive path is
  found, or when the snapshot cannot be fully scanned within the configured
  caps. The read-time scan runs even after an incident is resolved: a real
  secret in an immutable snapshot stays hidden.
  """
  @spec quarantine_status(Project.t(), Node.t() | nil, keyword()) :: :ok | :quarantined
  def quarantine_status(project, node, opts \\ [])

  def quarantine_status(_project, nil, _opts), do: :quarantined

  def quarantine_status(project, node, opts) do
    case quarantine_status_with_source(project, node, opts) do
      {:ok, status} -> status
      {:error, :unverifiable} -> :quarantined
    end
  end

  @doc """
  Like `quarantine_status/3`, but reports whether the answer is authoritative.

  `{:ok, :quarantined}` means an incident or a completed scan quarantines the
  snapshot (deterministic: the snapshot is immutable). `{:error, :unverifiable}`
  means the scan failed, so the caller may retry later instead of caching a
  transient `:quarantined`.
  """
  @spec quarantine_status_with_source(Project.t(), Node.t() | nil, keyword()) ::
          {:ok, :ok | :quarantined} | {:error, :unverifiable}
  def quarantine_status_with_source(project, node, opts \\ [])

  def quarantine_status_with_source(_project, nil, _opts), do: {:ok, :quarantined}

  def quarantine_status_with_source(project, node, opts) do
    if Incidents.blocking_node?(project.id, node.id) do
      {:ok, :quarantined}
    else
      scan_quarantine_status(project, node, opts)
    end
  end

  defp scan_quarantine_status(project, node, opts) do
    %{max_files: default_max_files, max_bytes: default_max_bytes} = scan_limits()
    max_files = Keyword.get(opts, :max_files) || default_max_files
    max_bytes = Keyword.get(opts, :max_bytes) || default_max_bytes

    case GitStore.walk_blobs(repo(project), node.git_commit_sha,
           max_files: max_files,
           max_bytes: max_bytes
         ) do
      {:ok, blobs} ->
        {:ok, if(PublicContent.quarantine?(blobs), do: :quarantined, else: :ok)}

      {:error, _reason} ->
        {:error, :unverifiable}
    end
  end

  @doc """
  File/byte caps for a full snapshot scan.

  Shared by `quarantine_status/3` and other public readers so every bounded
  scan uses the same configured limits. A snapshot that cannot be scanned
  within these caps is treated as unverifiable, never as safe.
  """
  @spec scan_limits() :: %{max_files: non_neg_integer(), max_bytes: non_neg_integer()}
  def scan_limits do
    %{
      max_files: config_int(:scan_max_files, 10_000),
      max_bytes: config_int(:scan_max_bytes, 16_777_216)
    }
  end

  @doc """
  List a directory in a node's snapshot with sensitive entries filtered.

  Returns `{:ok, %{entries, hidden_count, truncated?}}` or `{:error, :not_found}`.
  """
  @spec list_dir(Project.t(), Node.t(), String.t() | nil, keyword()) ::
          {:ok, %{entries: [map()], hidden_count: non_neg_integer(), truncated?: boolean()}}
          | {:error, :not_found}
  def list_dir(project, node, path, opts \\ []) do
    max_entries = Keyword.get(opts, :max_entries) || config_int(:tree_max_entries, 1000)
    filtered? = Keyword.get(opts, :filter, true)
    path = path || ""

    case GitStore.list_path(repo(project), node.git_commit_sha, path, max_entries: max_entries) do
      {:ok, entries, truncated?} ->
        {visible, hidden_count} =
          if filtered?, do: PublicContent.filter_entries(entries), else: {entries, 0}

        {:ok, %{entries: visible, hidden_count: hidden_count, truncated?: truncated?}}

      {:error, :not_a_directory} ->
        {:error, :not_found}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :unsafe_path} ->
        {:error, :not_found}
    end
  end

  @doc """
  Read a file from a node's snapshot with public secret redaction.

  Returns `{:ok, %{path, content, binary?, truncated?, redacted?}}`. Binary or
  oversized files return `content: nil` with the matching flag.
  """
  @spec read_file(Project.t(), Node.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, :not_found | :hidden}
  def read_file(project, node, path, opts \\ [])

  def read_file(project, node, path, opts) when is_binary(path) do
    filtered? = Keyword.get(opts, :filter, true)

    if filtered? and PublicContent.sensitive_path?(path) and
         not PublicContent.allowed_sensitive_path?(path) do
      {:error, :hidden}
    else
      max_bytes = Keyword.get(opts, :max_bytes) || config_int(:file_max_bytes, 524_288)
      max_lines = Keyword.get(opts, :max_lines) || config_int(:file_max_lines, 2000)

      case GitStore.read_path(repo(project), node.git_commit_sha, path, max_bytes: max_bytes) do
        {:ok, content} ->
          if PublicContent.binary?(content) do
            {:ok, %{path: path, content: nil, binary?: true, truncated?: false, redacted?: false}}
          else
            {rendered, findings} =
              if filtered? do
                PublicContent.redact(content)
              else
                {content, []}
              end

            {display, lines_truncated?} = truncate_lines(rendered, max_lines)

            {:ok,
             %{
               path: path,
               content: display,
               binary?: false,
               truncated?: lines_truncated?,
               redacted?: findings != []
             }}
          end

        {:error, :too_large} ->
          {:ok, %{path: path, content: nil, binary?: false, truncated?: true, redacted?: false}}

        {:error, _reason} ->
          {:error, :not_found}
      end
    end
  end

  def read_file(_project, _node, _path, _opts), do: {:error, :not_found}

  @doc """
  Read the root README from a node's snapshot and redact it.

  Returns `{:ok, %{name, markdown, binary?, truncated?, redacted?}}` or
  `{:error, :not_found}`.
  """
  @spec read_readme(Project.t(), Node.t(), keyword()) :: {:ok, map()} | {:error, :not_found}
  def read_readme(project, node, opts \\ []) do
    max_bytes = Keyword.get(opts, :max_bytes) || config_int(:readme_max_bytes, 262_144)
    filtered? = Keyword.get(opts, :filter, true)
    repo = repo(project)

    result =
      Enum.find_value(readme_candidates(repo, node.git_commit_sha), fn name ->
        case read_readme_candidate(repo, node.git_commit_sha, name, max_bytes, filtered?) do
          :not_found -> nil
          {:ok, _readme} = ok -> ok
        end
      end)

    result || {:error, :not_found}
  end

  defp readme_candidates(repo, commit_sha) do
    case GitStore.list_path(repo, commit_sha, "", max_entries: 1000) do
      {:ok, entries, _truncated?} ->
        entries
        |> Enum.filter(fn entry ->
          entry.type == :blob and Regex.match?(~r/^readme(\.md|\.markdown|\.txt)?$/i, entry.name)
        end)
        |> Enum.sort_by(&readme_rank(&1.name))
        |> Enum.map(& &1.name)

      {:error, _reason} ->
        @readme_names
    end
  end

  defp readme_rank(name) do
    case String.downcase(name) do
      "readme.md" -> 0
      "readme.markdown" -> 1
      "readme" -> 2
      "readme.txt" -> 3
      _ -> 4
    end
  end

  defp read_readme_candidate(repo, commit_sha, name, max_bytes, filtered?) do
    if filtered? and PublicContent.sensitive_path?(name) and
         not PublicContent.allowed_sensitive_path?(name) do
      :not_found
    else
      case GitStore.read_path(repo, commit_sha, name, max_bytes: max_bytes) do
        {:ok, content} ->
          if PublicContent.binary?(content) do
            {:ok,
             %{
               name: name,
               markdown: nil,
               binary?: true,
               truncated?: false,
               redacted?: false
             }}
          else
            {markdown, findings} =
              if filtered? do
                PublicContent.redact(content)
              else
                {content, []}
              end

            {:ok,
             %{
               name: name,
               markdown: markdown,
               binary?: false,
               truncated?: false,
               redacted?: findings != []
             }}
          end

        {:error, :too_large} ->
          {:ok,
           %{
             name: name,
             markdown: nil,
             binary?: false,
             truncated?: true,
             redacted?: false
           }}

        {:error, _reason} ->
          :not_found
      end
    end
  end

  defp repo(project), do: ProjectGit.open(project.id)

  defp truncate_lines(content, max_lines) when max_lines <= 0 do
    {"", content != ""}
  end

  defp truncate_lines(content, max_lines) do
    lines = String.split(content, "\n")

    if length(lines) > max_lines do
      {lines |> Enum.take(max_lines) |> Enum.join("\n"), true}
    else
      {content, false}
    end
  end

  defp config_int(key, default) do
    case Application.get_env(:cadence_server, key, default) do
      value when is_integer(value) -> value
      _ -> default
    end
  end

  defp ordered_nodes(project_id) do
    from(n in Node,
      where: n.project_id == ^project_id,
      order_by: [desc: n.created_at, desc: n.id]
    )
  end

  defp page_query(query, opts) do
    case Keyword.get(opts, :limit) do
      page_size when is_integer(page_size) and page_size > 0 ->
        skip = page_offset(Keyword.get(opts, :offset))

        query
        |> limit(^page_size)
        |> offset(^skip)

      _ ->
        # Without a limit there is no page, so an offset alone is ignored
        # rather than silently dropping the newest rows.
        query
    end
  end

  defp page_offset(value) when is_integer(value) and value > 0, do: value
  defp page_offset(_value), do: 0

  defp page_size(value) when is_integer(value) and value > 0, do: value
  defp page_size(_value), do: node_page_size()

  defp clamp_page(page, total_pages) when is_integer(page) and page > 0,
    do: min(page, total_pages)

  defp clamp_page(_page, _total_pages), do: 1

  defp ceil_div(total, size), do: div(total + size - 1, size)

  defp empty_node_page(size) do
    %{
      nodes: [],
      offset: 0,
      limit: size,
      page: 1,
      total: 0,
      total_pages: 1,
      has_prev: false,
      has_next: false
    }
  end
end
