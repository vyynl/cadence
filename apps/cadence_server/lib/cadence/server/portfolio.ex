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

  Returns `%{project: Project.t(), node_count: non_neg_integer()}` entries.
  """
  @spec list_projects() :: [%{project: Project.t(), node_count: non_neg_integer()}]
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

    Enum.map(projects, fn project ->
      %{project: project, node_count: Map.get(counts, project.id, 0)}
    end)
  end

  @doc """
  List a project's nodes, newest first with a deterministic tie-break.

  Used by the full public DAG and the preview resolver.
  """
  @spec list_nodes(Ecto.UUID.t() | String.t()) :: [Node.t()]
  def list_nodes(project_id) do
    with {:ok, project_id} <- UUID.cast(project_id) do
      Repo.all(ordered_nodes(project_id))
    else
      :error -> []
    end
  end

  @doc """
  Resolve the preview node (spec §4.4): pinned, then functioning, then newest.
  """
  @spec preview_node(Ecto.UUID.t() | String.t()) :: Node.t() | nil
  def preview_node(project_id) do
    with {:ok, project_id} <- UUID.cast(project_id) do
      ordered = ordered_nodes(project_id)

      Repo.one(from(n in ordered, where: n.pinned == true, limit: 1)) ||
        Repo.one(
          from(n in ordered,
            where: fragment("? = ANY(?)", "functioning", n.flags),
            limit: 1
          )
        ) ||
        Repo.one(from(n in ordered, limit: 1))
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
    if Incidents.blocking_node?(project.id, node.id) do
      :quarantined
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
        if PublicContent.quarantine?(blobs), do: :quarantined, else: :ok

      {:error, _reason} ->
        :quarantined
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
end
