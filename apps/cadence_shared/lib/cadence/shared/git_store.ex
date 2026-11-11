defmodule Cadence.Shared.GitStore do
  @moduledoc """
  A content-addressed Git object store (blob/tree/commit), specialized for
  Cadence's DAG-of-session-nodes model.

  Cadence has no branches, refs, or tags of its own: every session is an
  immutable commit addressed by its SHA, and parent links live in the `Node`
  schema rather than in the object store. This module implements the object
  layer only, with a ref-less commit writer. A separate read-only import layer
  (`detect_repository/1`, `read_ref/2`, `resolve_revision/2`, `walk_commits/3`,
  `copy_commit_objects/4`) can inspect an existing Git repository and copy its
  history into a Cadence store; it never writes refs into the destination.

  Objects are written loose (zlib-compressed files under `objects/<2>/<38>`),
  as Git does. Reads also consult packfiles (`objects/pack/*.pack` plus their
  `.idx` indexes) when the loose file is absent, so callers never need to know
  which layout a store uses. Pack writes are explicit (`pack_objects/3`);
  no background process belongs in this shared module (spec §13 Phase 7).

  The Git object format (blob/tree/commit byte layout, SHA-1 content
  addressing, zlib compression) is a public standard. The encoding approach is
  derived from the pure-Elixir implementation in `awetzel/gitex` (MIT), which
  served as a reference for serializing those objects.
  """

  alias Cadence.Shared.GitStore.{Cache, Pack}
  alias Cadence.Shared.GitStore.Pack.Index

  @type t :: %__MODULE__{home_dir: Path.t()}
  @type sha :: String.t()
  @type author :: %{name: String.t(), email: String.t()}
  @type entry :: %{name: String.t(), mode: String.t(), type: :blob | :tree | :commit, ref: sha()}
  @type object :: %{sha: sha(), type: :blob | :tree | :commit, data: binary()}
  @type repository :: %{kind: :worktree | :bare, path: Path.t(), git_dir: Path.t()}
  @type walk_result :: %{commits: [commit()], truncated: boolean(), shallow: boolean()}
  @type commit :: %{
          hash: sha(),
          tree: sha(),
          parent: [sha()],
          author: author(),
          committer: author(),
          message: String.t()
        }

  @dir_mode "40000"
  @gitlink_mode "160000"
  @file_mode "100644"

  # Never snapshotted: Cadence's own store lives outside the work tree, but a
  # work tree may contain nested repositories whose `.git` must not be captured.
  @always_ignored [".git"]

  defstruct home_dir: nil

  @doc """
  Initialize an object store at `path`.

  With `bare: true` (default `false`) the objects live directly under `path`;
  otherwise they live under `path/.git`. Only the `objects/` directory is
  created — Cadence keeps no refs, HEAD, or working-tree metadata.
  """
  @spec init(Path.t(), keyword()) :: t()
  def init(path, opts \\ []) do
    repo = open(path, opts)

    File.mkdir_p!(Path.join([repo.home_dir, "objects", "info"]))
    File.mkdir_p!(Path.join([repo.home_dir, "objects", "pack"]))

    repo
  end

  @doc """
  Return a handle to an existing store without creating anything.

  Use this for read-only access (e.g. reconstructing a diff); unlike `init/2`
  it never touches the filesystem, so callers cannot accidentally recreate
  directories they are only reading.
  """
  @spec open(Path.t(), keyword()) :: t()
  def open(path, opts \\ []) do
    bare = Keyword.get(opts, :bare, false)
    home_dir = if bare, do: Path.expand(path), else: Path.expand(Path.join(path, ".git"))
    %__MODULE__{home_dir: home_dir}
  end

  ## Read-only repository import layer

  @doc """
  Locate the Git directory for a repository at `path`.

  Accepts a worktree (a `.git` directory or a `.git` redirect file) and a bare
  repository. Nothing is created or changed. Returns
  `{:error, :not_a_repository}` or `{:error, :invalid_gitfile}`.
  """
  @spec detect_repository(Path.t()) :: {:ok, repository()} | {:error, term()}
  def detect_repository(path) when is_binary(path) do
    root = Path.expand(path)
    dot_git = Path.join(root, ".git")

    cond do
      File.dir?(dot_git) ->
        {:ok, %{kind: :worktree, path: root, git_dir: dot_git}}

      File.regular?(dot_git) ->
        resolve_gitfile(root, dot_git)

      repository_dir?(root) ->
        {:ok, %{kind: :bare, path: root, git_dir: root}}

      true ->
        {:error, :not_a_repository}
    end
  end

  def detect_repository(_path), do: {:error, :not_a_repository}

  @doc """
  Resolve `HEAD` or a full ref name to a SHA.

  Loose refs are read first, then `packed-refs`. Only refs under `refs/` are
  accepted (no traversal). Returns `{:error, :not_found}` for a missing ref.
  """
  @spec read_ref(t(), String.t()) :: {:ok, sha()} | {:error, :not_found}
  def read_ref(repo, ref) when is_binary(ref) do
    case resolve_ref(repo, ref, 0) do
      {:ok, sha} -> {:ok, sha}
      :error -> {:error, :not_found}
    end
  end

  def read_ref(_repo, _ref), do: {:error, :not_found}

  @doc """
  Resolve a revision to a commit SHA.

  Accepts a 40-hex SHA, `HEAD`, a local branch, or a tag name. Annotated tags
  are peeled to the commit they point at.
  """
  @spec resolve_revision(t(), String.t()) :: {:ok, sha()} | {:error, term()}
  def resolve_revision(repo, rev) when is_binary(rev) do
    cond do
      valid_sha?(rev) ->
        peel_to_commit(repo, rev)

      rev == "HEAD" ->
        case read_ref(repo, "HEAD") do
          {:ok, sha} -> peel_to_commit(repo, sha)
          {:error, :not_found} -> {:error, :not_found}
        end

      String.starts_with?(rev, "refs/") ->
        case read_ref(repo, rev) do
          {:ok, sha} -> peel_to_commit(repo, sha)
          {:error, :not_found} -> {:error, :not_found}
        end

      true ->
        ["refs/heads/#{rev}", "refs/tags/#{rev}", "refs/remotes/#{rev}"]
        |> Enum.find_value({:error, :not_found}, fn ref ->
          case read_ref(repo, ref) do
            {:ok, sha} -> peel_to_commit(repo, sha)
            {:error, :not_found} -> nil
          end
        end)
    end
  end

  def resolve_revision(_repo, _rev), do: {:error, :not_found}

  @doc """
  The commit SHAs listed in the repository's `shallow` file.

  A shallow clone stores its boundary commits there; their parents are absent.
  """
  @spec shallow_commits(t()) :: MapSet.t(sha())
  def shallow_commits(repo) do
    case File.read(Path.join(repo.home_dir, "shallow")) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&valid_sha?/1)
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  @doc """
  Walk the commit graph reachable from `tips` in parents-first order.

  Bounded by `:max` (default 1,000). A walk that would exceed it returns
  `{:error, {:too_many_commits, max}}` unless `:truncate` is true; in that case
  the collected subset is returned with `truncated: true` and boundary commits
  become roots. Shallow boundaries are always treated as roots and reported as
  `shallow: true`. Any other missing object is an error.
  """
  @spec walk_commits(t(), [sha()], keyword()) :: {:ok, walk_result()} | {:error, term()}
  def walk_commits(repo, tips, opts \\ [])

  def walk_commits(repo, tips, opts) when is_list(tips) do
    max = Keyword.get(opts, :max, 1_000)
    truncate? = Keyword.get(opts, :truncate, false) == true
    shallow = shallow_commits(repo)

    tips =
      tips
      |> Enum.filter(&valid_sha?/1)
      |> Enum.uniq()

    queue = Enum.reduce(tips, :queue.new(), fn sha, q -> :queue.in(sha, q) end)
    acc = %{commits: %{}, truncated: false, shallow: false}

    with {:ok, acc} <- collect_commits(repo, queue, MapSet.new(), max, truncate?, shallow, acc),
         {:ok, commits} <- sort_commits(acc.commits) do
      {:ok, %{commits: commits, truncated: acc.truncated, shallow: acc.shallow}}
    end
  end

  def walk_commits(_repo, _tips, _opts), do: {:error, :invalid_tips}

  @doc """
  Copy commits and their tree/blob closure from `source` into `target`.

  `commits` may be decoded commit maps (from `walk_commits/3`) or SHAs. Shared
  trees are walked once per call and objects already in `target` are skipped.
  Gitlinks (submodule entries) are not copied; their targets live in another
  repository.

  Options:
    * `:max_blob_bytes` — reject larger blobs with
      `{:error, {:blob_too_large, sha, size}}` (default `:infinity`).
  """
  @spec copy_commit_objects(t(), t(), [commit() | sha()], keyword()) ::
          {:ok, %{objects: non_neg_integer(), bytes: non_neg_integer()}} | {:error, term()}
  def copy_commit_objects(source, target, commits, opts \\ [])

  def copy_commit_objects(source, target, commits, opts) when is_list(commits) do
    acc = %{
      objects: 0,
      bytes: 0,
      trees: MapSet.new(),
      written: MapSet.new(),
      max_blob: Keyword.get(opts, :max_blob_bytes, :infinity)
    }

    commits
    |> Enum.reduce_while({:ok, acc}, fn commit, {:ok, acc} ->
      with {:ok, sha, tree} <- commit_target(source, commit),
           {:ok, acc} <- copy_commit(source, target, sha, acc),
           {:ok, acc} <- copy_tree(source, target, tree, acc) do
        {:cont, {:ok, acc}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, %{objects: acc.objects, bytes: acc.bytes}}
      {:error, reason} -> {:error, reason}
    end
  end

  def copy_commit_objects(_source, _target, _commits, _opts), do: {:error, :invalid_commits}

  @doc """
  List the repository's local branch and tag refs.

  Loose refs are read first and win over `packed-refs`; peeled tag lines and
  refs outside `refs/heads` / `refs/tags` are ignored. Returns
  `{:ok, [%{name: ref, sha: sha}]}` sorted by name. Nothing is created or
  changed.
  """
  @spec list_refs(t()) :: {:ok, [%{name: String.t(), sha: sha()}]}
  def list_refs(repo) do
    refs =
      repo.home_dir
      |> Path.join("refs")
      |> list_loose_refs("refs")
      |> then(&Map.merge(read_packed_refs(repo), &1))

    {:ok,
     refs
     |> Enum.map(fn {name, sha} -> %{name: name, sha: sha} end)
     |> Enum.sort_by(& &1.name)}
  end

  @doc """
  Preflight the blob sizes of commits without writing anything.

  Every blob reachable from the commits' trees is read at most once and cached
  by SHA. `:max_blob_bytes` (default `:infinity`, `0`/`:infinity` disable the
  check) rejects a larger blob with `{:error, {:blob_too_large, path, size}}`
  where `path` is the first offending path in deterministic tree order.

  Returns `{:ok, %{blobs: n, bytes: n, largest_node_bytes: n}}`: unique blob
  count and bytes, plus the largest per-commit tree closure (the estimate for
  one node's push payload). Shared subtrees are counted once per commit, which
  matches `objects_from/2`'s per-node signal.
  """
  @spec preflight_blobs(t(), [commit()], keyword()) ::
          {:ok,
           %{
             blobs: non_neg_integer(),
             bytes: non_neg_integer(),
             largest_node_bytes: non_neg_integer()
           }}
          | {:error, term()}
  def preflight_blobs(repo, commits, opts \\ [])

  def preflight_blobs(repo, commits, opts) when is_list(commits) do
    max = Keyword.get(opts, :max_blob_bytes, :infinity)
    max = if max in [0, nil], do: :infinity, else: max

    acc = %{sizes: %{}, blobs: 0, bytes: 0, largest: 0}

    commits
    |> Enum.reduce_while({:ok, acc}, fn commit, {:ok, acc} ->
      case measure_commit(repo, commit, max, acc) do
        {:ok, node_bytes, acc} ->
          {:cont, {:ok, %{acc | largest: max(acc.largest, node_bytes)}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, %{blobs: acc.blobs, bytes: acc.bytes, largest_node_bytes: acc.largest}}
      {:error, reason} -> {:error, reason}
    end
  end

  def preflight_blobs(_repo, _commits, _opts), do: {:error, :invalid_commits}

  @doc "Store a blob and return its SHA."
  @spec write_blob(t(), iodata()) :: sha()
  def write_blob(repo, data), do: write_object(repo, "blob", IO.iodata_to_binary(data))

  @doc "Read a blob by SHA, or `nil` if absent."
  @spec read_blob(t(), sha()) :: binary() | nil
  def read_blob(repo, sha) do
    case read_object(repo, sha) do
      {:blob, data} -> data
      _ -> nil
    end
  end

  @doc """
  Store a tree from a list of `entry` maps and return its SHA.

  Entries are sorted per Git's rule (directories sort as if their name had a
  trailing `/`) so the encoded tree is canonical.
  """
  @spec write_tree(t(), [entry()]) :: sha()
  def write_tree(repo, entries), do: write_object(repo, "tree", encode_tree(entries))

  @doc """
  Recursively hash a directory on disk into a tree SHA.

  Regular files become blobs, subdirectories become trees. Other entry types
  (symlinks, sockets, ...) are skipped.

  `.git` directories are always skipped so nested repositories are never
  snapshotted. Additional entry names can be skipped with `ignore: [names]`;
  names match the basename at any depth (e.g. `_build`, `node_modules`).
  """
  @spec build_tree(t(), Path.t(), keyword()) :: sha()
  def build_tree(repo, dir, opts \\ []) do
    ignore = Keyword.get(opts, :ignore, [])

    entries =
      dir
      |> File.ls!()
      |> Enum.sort()
      |> Enum.flat_map(&tree_entry(repo, dir, &1, ignore, opts))

    write_tree(repo, entries)
  end

  defp tree_entry(repo, dir, name, ignore, opts) do
    if ignored?(name, ignore) do
      []
    else
      path = Path.join(dir, name)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} ->
          [%{name: name, mode: @dir_mode, type: :tree, ref: build_tree(repo, path, opts)}]

        {:ok, %File.Stat{type: :regular}} ->
          case File.read(path) do
            {:ok, data} ->
              [%{name: name, mode: @file_mode, type: :blob, ref: write_blob(repo, data)}]

            {:error, :enoent} ->
              []
          end

        _ ->
          []
      end
    end
  end

  defp ignored?(name, ignore), do: name in @always_ignored or name in ignore

  @doc """
  Write a tree from an in-memory `%{path => content}` map and return its SHA.

  Paths are slash-separated and every segment must be a safe entry name;
  content must be a binary. `.git` segments are rejected for the same reason
  `build_tree/2` always ignores them: Cadence must never materialize nested
  repository metadata. Nested directories are created only for the parents of
  written files — directories with no files are never represented, matching
  Git's tree model.

  Identical content is stored once because blobs are content-addressed. An
  empty map writes Git's canonical empty tree.

  Returns `{:error, :unsafe_path}` for a malformed/escaping path,
  `{:error, :invalid_content}` for non-binary content, and
  `{:error, :path_conflict}` when one path is both a file and a directory
  (for example `"a"` and `"a/b"`).
  """
  @spec put_files(t(), %{String.t() => binary()}) ::
          {:ok, sha()} | {:error, :unsafe_path | :invalid_content | :path_conflict}
  def put_files(repo, files) when is_map(files) do
    with {:ok, nested} <- nest_files(files) do
      {:ok, write_nested_tree(repo, nested)}
    end
  end

  def put_files(_repo, _files), do: {:error, :invalid_content}

  @doc """
  Overlay `files` onto an existing tree and return the new tree SHA.

  `files` is a `%{path => content}` map using the same path rules as
  `put_files/2`: every path is relative and traversal-free, `.git` segments are
  rejected, and conflicting file/directory entries return
  `{:error, :path_conflict}`. Untouched entries keep their original tree refs;
  only the directories named by `files` are read and rewritten.

  Returns `{:error, :missing_object}` when `tree_sha` is not a tree in the
  store.
  """
  @spec merge_files(t(), sha(), %{String.t() => binary()}) ::
          {:ok, sha()}
          | {:error, :unsafe_path | :invalid_content | :path_conflict | :missing_object}
  def merge_files(repo, tree_sha, files) when is_binary(tree_sha) and is_map(files) do
    with {:ok, incoming} <- nest_files(files),
         {:ok, merged} <- merge_tree(repo, tree_sha, incoming) do
      {:ok, merged}
    end
  end

  def merge_files(_repo, _tree_sha, _files), do: {:error, :invalid_content}

  # Recurse only into the subtrees named by `incoming`; untouched entries keep
  # their original refs (and the whole tree keeps its content-addressed SHA when
  # nothing changed).
  defp merge_tree(repo, tree_sha, incoming) do
    case read_tree(repo, tree_sha) do
      nil ->
        {:error, :missing_object}

      entries ->
        incoming
        |> Enum.reduce_while({:ok, entries}, fn {name, value}, {:ok, acc} ->
          existing = Enum.find(acc, &(&1.name == name))

          case merge_entry(repo, name, existing, value) do
            {:ok, entry} -> {:cont, {:ok, put_entry(acc, name, entry)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, entries} -> {:ok, write_tree(repo, entries)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp merge_entry(repo, name, nil, {:file, content}) do
    {:ok, %{name: name, mode: @file_mode, type: :blob, ref: write_blob(repo, content)}}
  end

  defp merge_entry(repo, name, nil, subtree) when is_map(subtree) do
    {:ok, %{name: name, mode: @dir_mode, type: :tree, ref: write_nested_tree(repo, subtree)}}
  end

  defp merge_entry(repo, _name, %{type: :blob} = existing, {:file, content}) do
    {:ok, %{existing | ref: write_blob(repo, content)}}
  end

  defp merge_entry(repo, _name, %{type: :tree} = existing, subtree) when is_map(subtree) do
    case merge_tree(repo, existing.ref, subtree) do
      {:ok, ref} -> {:ok, %{existing | ref: ref}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp merge_entry(_repo, _name, _existing, _value), do: {:error, :path_conflict}

  defp put_entry(entries, name, entry) do
    if Enum.any?(entries, &(&1.name == name)) do
      Enum.map(entries, fn existing -> if existing.name == name, do: entry, else: existing end)
    else
      [entry | entries]
    end
  end

  defp nest_files(files) do
    Enum.reduce_while(files, {:ok, %{}}, fn {path, content}, {:ok, acc} ->
      with {:ok, segments} <- split_path(path),
           :ok <- reject_ignored_segments(segments),
           :ok <- validate_content(content),
           {:ok, nested} <- insert_file(acc, segments, content) do
        {:cont, {:ok, nested}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp reject_ignored_segments(segments) do
    if Enum.any?(segments, &(&1 in @always_ignored)) do
      {:error, :unsafe_path}
    else
      :ok
    end
  end

  defp validate_content(content) when is_binary(content), do: :ok
  defp validate_content(_content), do: {:error, :invalid_content}

  defp insert_file(tree, [name], content) do
    case Map.get(tree, name) do
      nil -> {:ok, Map.put(tree, name, {:file, content})}
      {:file, _existing} -> {:ok, Map.put(tree, name, {:file, content})}
      nested when is_map(nested) -> {:error, :path_conflict}
    end
  end

  defp insert_file(tree, [name | rest], content) do
    case Map.get(tree, name) do
      {:file, _existing} ->
        {:error, :path_conflict}

      nil ->
        {:ok, subtree} = insert_file(%{}, rest, content)
        {:ok, Map.put(tree, name, subtree)}

      nested when is_map(nested) ->
        {:ok, subtree} = insert_file(nested, rest, content)
        {:ok, Map.put(tree, name, subtree)}
    end
  end

  defp write_nested_tree(repo, nested) do
    entries =
      Enum.map(nested, fn
        {name, {:file, content}} ->
          %{name: name, mode: @file_mode, type: :blob, ref: write_blob(repo, content)}

        {name, subtree} when is_map(subtree) ->
          %{name: name, mode: @dir_mode, type: :tree, ref: write_nested_tree(repo, subtree)}
      end)

    write_tree(repo, entries)
  end

  @doc "Read a tree by SHA, returning its entries, or `nil` if absent."
  @spec read_tree(t(), sha()) :: [entry()] | nil
  def read_tree(repo, sha) do
    case read_object(repo, sha) do
      {:tree, data} -> decode_tree(data)
      _ -> nil
    end
  end

  @doc """
  Write a commit referencing `tree`, with `parents` (a list of commit SHAs,
  empty for a root) and an author identity. Returns the commit SHA.

  This never touches refs — Cadence records the commit SHA and its parents in
  the `Node` schema.
  """
  @spec write_commit(t(), sha(), [sha()], author(), String.t()) :: sha()
  def write_commit(repo, tree, parents, author, message) do
    commit = %{tree: tree, parent: parents, author: author, committer: author, message: message}
    write_object(repo, "commit", encode_commit(commit))
  end

  @doc "Read a commit by SHA, or `nil` if absent."
  @spec read_commit(t(), sha()) :: commit() | nil
  def read_commit(repo, sha) do
    case read_object(repo, sha) do
      {:commit, data} -> decode_commit(data, sha)
      _ -> nil
    end
  end

  @doc """
  Read a regular file from the tree of `commit_sha` at a slash-separated path.

  Returns `{:ok, content}` or `{:error, reason}`, where `reason` is one of
  `:not_found`, `:not_a_file`, `:too_large`, or `:unsafe_path`. Content larger
  than `:max_bytes` (default 1 MiB) is rejected before it is returned.

  Paths are resolved inside the commit tree; absolute paths, `.`, `..`, empty
  segments, and backslashes are rejected so untrusted path input cannot escape
  the tree.
  """
  @spec read_path(t(), sha(), String.t(), keyword()) ::
          {:ok, binary()}
          | {:error, :not_found | :not_a_file | :too_large | :unsafe_path}
  def read_path(repo, commit_sha, path, opts \\ []) do
    max_bytes = Keyword.get(opts, :max_bytes, 1_048_576)

    with {:ok, segments} <- split_path(path),
         %{tree: tree} <- read_commit(repo, commit_sha) do
      read_path_segments(repo, tree, segments, max_bytes)
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp split_path(path) when is_binary(path) do
    segments = String.split(path, "/")

    if segments != [] and Enum.all?(segments, &non_empty_safe_name?/1) do
      {:ok, segments}
    else
      {:error, :unsafe_path}
    end
  end

  defp split_path(_path), do: {:error, :unsafe_path}

  defp non_empty_safe_name?(name), do: name != "" and safe_name?(name)

  defp read_path_segments(repo, tree_sha, [name], max_bytes) do
    case find_entry(repo, tree_sha, name) do
      %{type: :blob, ref: ref} ->
        case read_blob(repo, ref) do
          nil -> {:error, :not_found}
          data when byte_size(data) <= max_bytes -> {:ok, data}
          _data -> {:error, :too_large}
        end

      %{type: :tree} ->
        {:error, :not_a_file}

      %{type: :commit} ->
        {:error, :not_a_file}

      nil ->
        {:error, :not_found}
    end
  end

  defp read_path_segments(repo, tree_sha, [name | rest], max_bytes) do
    case find_entry(repo, tree_sha, name) do
      %{type: :tree, ref: ref} -> read_path_segments(repo, ref, rest, max_bytes)
      %{type: :blob} -> {:error, :not_found}
      %{type: :commit} -> {:error, :not_a_file}
      nil -> {:error, :not_found}
    end
  end

  defp find_entry(repo, tree_sha, name) do
    case read_tree(repo, tree_sha) do
      nil -> nil
      entries -> Enum.find(entries, &(&1.name == name))
    end
  end

  @doc """
  List entries in a directory of `commit_sha`'s tree.

  `path` may be `""` or `"/"` for the root. Returns `{:ok, entries, truncated?}`
  where entries are maps with `:name`, `:type` (`:tree` or `:blob`), and `:path`.
  Directories sort before files, then by case-insensitive name.

  `:max_entries` (default 1000) caps the result. `truncated?` is true when the
  directory had more entries than the cap.
  """
  @spec list_path(t(), sha(), String.t() | nil, keyword()) ::
          {:ok, [%{name: String.t(), type: :tree | :blob, path: String.t()}], boolean()}
          | {:error, :not_found | :not_a_directory | :unsafe_path}
  def list_path(repo, commit_sha, path, opts \\ []) do
    max_entries = max(Keyword.get(opts, :max_entries, 1000), 0)

    with {:ok, segments} <- split_dir_path(path),
         %{tree: tree} <- read_commit(repo, commit_sha),
         {:ok, tree_sha} <- resolve_dir(repo, tree, segments) do
      case read_tree(repo, tree_sha) do
        nil ->
          {:error, :not_found}

        entries ->
          normalized =
            entries
            |> Enum.map(&%{name: &1.name, type: &1.type, path: join_path(path, &1.name)})
            |> sort_entries()

          {:ok, Enum.take(normalized, max_entries), length(normalized) > max_entries}
      end
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Walk every blob reachable from `commit_sha`, returning path/content/size.

  Caps at `:max_files` (default 1000) and `:max_bytes` (default 4 MiB). Returns
  `{:error, :too_many_files | :too_many_bytes}` when a cap is exceeded, which
  callers should treat as "cannot verify this snapshot".
  """
  @spec walk_blobs(t(), sha(), keyword()) ::
          {:ok, [%{path: String.t(), ref: sha(), size: non_neg_integer(), content: binary()}]}
          | {:error, :missing_object | :not_a_commit | :too_many_files | :too_many_bytes}
  def walk_blobs(repo, commit_sha, opts \\ []) do
    max_files = max(Keyword.get(opts, :max_files, 1000), 0)
    max_bytes = max(Keyword.get(opts, :max_bytes, 4_194_304), 0)

    case read_object(repo, commit_sha) do
      {:commit, _data} ->
        commit = read_commit(repo, commit_sha)

        case walk_tree_blobs(repo, commit.tree, "", max_files, max_bytes, [], 0, 0) do
          {:ok, blobs, _count, _bytes} -> {:ok, Enum.sort_by(blobs, & &1.path)}
          error -> error
        end

      {_other, _data} ->
        {:error, :not_a_commit}

      nil ->
        {:error, :missing_object}
    end
  end

  defp walk_tree_blobs(repo, tree_sha, prefix, max_files, max_bytes, acc, count, bytes) do
    case read_tree(repo, tree_sha) do
      nil ->
        {:error, :missing_object}

      entries ->
        entries
        |> Enum.reduce_while({:ok, acc, count, bytes}, fn entry, {:ok, acc, count, bytes} ->
          path = join_path(prefix, entry.name)

          case entry.type do
            :tree ->
              case walk_tree_blobs(
                     repo,
                     entry.ref,
                     path,
                     max_files,
                     max_bytes,
                     acc,
                     count,
                     bytes
                   ) do
                {:ok, acc, count, bytes} -> {:cont, {:ok, acc, count, bytes}}
                error -> {:halt, error}
              end

            :commit ->
              # A submodule (gitlink) is not a file in this repository.
              {:cont, {:ok, acc, count, bytes}}

            :blob ->
              case read_blob(repo, entry.ref) do
                nil ->
                  {:halt, {:error, :missing_object}}

                content ->
                  count = count + 1
                  bytes = bytes + byte_size(content)

                  cond do
                    count > max_files ->
                      {:halt, {:error, :too_many_files}}

                    bytes > max_bytes ->
                      {:halt, {:error, :too_many_bytes}}

                    true ->
                      item = %{
                        path: path,
                        ref: entry.ref,
                        size: byte_size(content),
                        content: content
                      }

                      {:cont, {:ok, [item | acc], count, bytes}}
                  end
              end
          end
        end)
    end
  end

  defp split_dir_path(nil), do: {:ok, []}
  defp split_dir_path(path) when path in ["", "/"], do: {:ok, []}
  defp split_dir_path(path) when is_binary(path), do: split_path(path)
  defp split_dir_path(_path), do: {:error, :unsafe_path}

  defp resolve_dir(_repo, tree_sha, []), do: {:ok, tree_sha}

  defp resolve_dir(repo, tree_sha, [name | rest]) do
    case find_entry(repo, tree_sha, name) do
      %{type: :tree, ref: ref} -> resolve_dir(repo, ref, rest)
      %{type: :blob} -> {:error, :not_a_directory}
      %{type: :commit} -> {:error, :not_a_directory}
      nil -> {:error, :not_found}
    end
  end

  defp join_path(path, name) when path in [nil, "", "/"], do: name
  defp join_path(path, name), do: String.trim_trailing(path, "/") <> "/" <> name

  defp sort_entries(entries) do
    Enum.sort_by(entries, fn entry ->
      {if(entry.type == :tree, do: 0, else: 1), String.downcase(entry.name), entry.name}
    end)
  end

  @doc """
  Collect a commit and every tree/blob reachable from it.

  Returns the commit object first, followed by its tree and blobs in
  depth-first order. Objects shared between trees are emitted once. `data` is
  the raw object payload without Git's `<type> <size>\\0` header.
  """
  @spec objects_from(t(), sha()) :: {:ok, [object()]} | {:error, :missing_object | :not_a_commit}
  def objects_from(repo, commit_sha) do
    case read_object(repo, commit_sha) do
      {:commit, _data} ->
        case collect_objects(repo, commit_sha, MapSet.new(), []) do
          {:ok, objects, _visited} -> {:ok, Enum.reverse(objects)}
          {:error, reason} -> {:error, reason}
        end

      {_other, _data} ->
        {:error, :not_a_commit}

      nil ->
        {:error, :missing_object}
    end
  end

  @doc """
  Import raw objects into `repo`.

  Every object is validated before anything is written: the SHA must match the
  reconstructed Git object, the type must be known, and trees/commits must be
  structurally valid. Import is idempotent because the store is
  content-addressed.
  """
  @spec import_objects(t(), [object()]) :: :ok | {:error, term()}
  def import_objects(repo, objects) when is_list(objects) do
    with :ok <- validate_objects(objects) do
      Enum.each(objects, fn %{type: type, data: data} -> write_raw(repo, type, data) end)
      :ok
    end
  end

  def import_objects(_repo, other), do: {:error, {:invalid_objects, other}}

  @doc """
  Write a raw object payload (`data` excludes the Git header) and return its
  SHA. This is the low-level primitive used by sync imports.
  """
  @spec write_raw(t(), :blob | :tree | :commit | :tag, binary()) :: sha()
  def write_raw(repo, type, data)
      when type in [:blob, :tree, :commit, :tag] and is_binary(data) do
    write_object(repo, Atom.to_string(type), data)
  end

  @doc """
  Return whether an object exists in the store.

  Checks the loose object first, then every pack index. A SHA without a valid
  40-hex shape is always `false`.
  """
  @spec has_object?(t(), sha()) :: boolean()
  def has_object?(repo, sha) when is_binary(sha) and byte_size(sha) == 40 do
    valid_sha?(sha) and (loose_object?(repo, sha) or packed_object?(repo, sha))
  end

  def has_object?(_repo, _sha), do: false

  ## Packs

  @doc """
  Return the pack indexes for a store.

  Each entry is `%{name, pack_path, idx_path, offsets, ends, pack_checksum}`,
  where `offsets` maps object SHAs to byte offsets in the pack and `ends` maps
  each offset to the end of its compressed slice. Corrupt, orphaned, or
  checksum-mismatched pairs are skipped.
  """
  @spec packs(t()) :: [map()]
  def packs(repo), do: Cache.packs(repo.home_dir)

  @doc "Drop cached pack indexes for a store (call after writing a pack)."
  @spec invalidate_cache(t()) :: :ok
  def invalidate_cache(repo), do: Cache.invalidate(repo.home_dir)

  @doc """
  Read any object by SHA, returning its Git type and payload.

  Reads loose first, then packs. Returns `{:error, :not_found}` for a missing
  or malformed SHA. This is the raw primitive the Phase 7b repacker needs to
  walk loose objects that no commit references.
  """
  @spec read_raw(t(), sha()) :: {:ok, {atom(), binary()}} | {:error, :not_found}
  def read_raw(repo, sha) do
    case read_object(repo, sha) do
      nil -> {:error, :not_found}
      {type, data} -> {:ok, {type, data}}
    end
  end

  @doc """
  Return the subset of `shas` that the store already holds.

  Bulk form of `has_object?/2` for the Phase 7c existence handshake: it reads
  the pack indexes once instead of once per SHA. Invalid SHAs are ignored.
  """
  @spec present_shas(t(), [sha()]) :: [sha()]
  def present_shas(repo, shas) when is_list(shas) do
    packs = packs(repo)

    Enum.filter(shas, fn sha ->
      valid_sha?(sha) and
        (loose_object?(repo, sha) or Enum.any?(packs, &Map.has_key?(&1.offsets, sha)))
    end)
  end

  @doc """
  Verify that `sha` is readable from a pack and still hashes to `sha`.

  This is the repacker's pre-deletion check: `read_raw/2` is loose-first, so it
  cannot prove that a packed copy is usable while the loose file still exists.
  Here the entry is read through the packs only (never the loose file) and the
  content is re-hashed against the SHA it is addressed by. Every pack that
  covers the SHA is tried, so a duplicate in a newer (repair) pack can still
  verify even if an older copy is corrupt.

  Returns `:ok`, `{:error, :not_packed}` when no usable pack covers the SHA, or
  `{:error, :corrupt}` when at least one covers it but none reads back
  correctly. Only packs whose trailer matches their index are considered.
  """
  @spec verify_packed(t(), sha()) :: :ok | {:error, :not_packed | :corrupt}
  def verify_packed(repo, sha) do
    case Enum.filter(packs(repo), &Map.has_key?(&1.offsets, sha)) do
      [] -> {:error, :not_packed}
      candidates -> verify_candidates(candidates, sha)
    end
  end

  defp verify_candidates([], _sha), do: {:error, :corrupt}

  defp verify_candidates([pack | rest], sha) do
    case Pack.read_object(pack.pack_path, pack.offsets, sha, ends: pack.ends) do
      {:ok, {type, data}} ->
        if object_sha(type, data) == sha, do: :ok, else: verify_candidates(rest, sha)

      {:error, _reason} ->
        verify_candidates(rest, sha)
    end
  end

  @doc """
  Read an object from its loose file only, returning its Git type and payload.

  Unlike `read_raw/2` this never falls back to a pack, so the repacker can tell
  "the loose copy is unreadable" from "the object is elsewhere". The content is
  re-hashed against `sha`: a decodable but different object (a file restored to
  the wrong path) is `:corrupt`, not a candidate for packing.

  Returns `{:error, :not_found}` for a malformed SHA or a missing file, and
  `{:error, :corrupt}` when the file does not decode to the object it claims.
  """
  @spec read_loose_raw(t(), sha()) ::
          {:ok, {atom(), binary()}} | {:error, :not_found | :corrupt}
  def read_loose_raw(repo, sha) when is_binary(sha) and byte_size(sha) == 40 do
    if valid_sha?(sha) do
      case read_loose_object(repo, sha) do
        {:ok, {type, data}} ->
          if object_sha(type, data) == sha, do: {:ok, {type, data}}, else: {:error, :corrupt}

        :not_found ->
          {:error, :not_found}

        :corrupt ->
          {:error, :corrupt}
      end
    else
      {:error, :not_found}
    end
  end

  def read_loose_raw(_repo, _sha), do: {:error, :not_found}

  @doc """
  List loose objects present in the store.

  Returns `%{sha, size, path}` maps sorted by SHA, where `size` is the on-disk
  (zlib-compressed) size. Used by the server repack slice (Phase 7b) to decide
  what is worth packing; it never reads object content.
  """
  @spec loose_objects(t()) :: [%{sha: sha(), size: non_neg_integer(), path: Path.t()}]
  def loose_objects(repo) do
    objects_dir = Path.join([repo.home_dir, "objects"])

    case File.ls(objects_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&Regex.match?(~r/^[0-9a-f]{2}$/, &1))
        |> Enum.flat_map(&loose_in_dir(objects_dir, &1))
        |> Enum.sort_by(& &1.sha)

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Pack `objects` into a new packfile + index and return their names.

  `objects` use the same shape as `objects_from/2` (`%{sha, type, data}`);
  `type` may be an atom or its string name. Every object is validated, the pack
  is written to a temporary file, verified by reading it back, and only then
  renamed into `objects/pack/`. Loose objects are left untouched — deletion is
  the repacker's decision (Phase 7b).

  Duplicate SHAs are dropped. Writing the same ordered set with the same
  options is idempotent: content addressing gives the same pack name, and the
  rename replaces identical bytes. Returns `{:error, :no_objects}` for an
  empty list.
  """
  @spec pack_objects(t(), [object()], keyword()) ::
          {:ok,
           %{
             name: String.t(),
             objects: non_neg_integer(),
             bytes: non_neg_integer(),
             pack_path: Path.t(),
             idx_path: Path.t()
           }}
          | {:error, term()}
  def pack_objects(repo, objects, opts \\ [])

  def pack_objects(_repo, [], _opts), do: {:error, :no_objects}

  def pack_objects(repo, objects, opts) when is_list(objects) do
    with :ok <- validate_objects(objects),
         {:ok, normalized} <- normalize_objects(objects) do
      normalized = Enum.uniq_by(normalized, & &1.sha)

      with {:ok, encoded} <- Pack.encode(normalized, opts) do
        write_pack(repo, normalized, encoded)
      end
    end
  end

  def pack_objects(_repo, _objects, _opts), do: {:error, :invalid_objects}

  defp write_pack(repo, objects, encoded) do
    dir = Path.join([repo.home_dir, "objects", "pack"])
    File.mkdir_p!(dir)

    name = "pack-" <> Base.encode16(encoded.checksum, case: :lower)
    pack_path = Path.join(dir, name <> ".pack")
    idx_path = Path.join(dir, name <> ".idx")
    idx_bin = Index.encode(encoded.entries, encoded.checksum)

    # A `.tmp` suffix keeps an interrupted write invisible to the cache's
    # `pack-*.idx` discovery; the pair is only renamed once verified.
    tmp = "tmp-#{System.unique_integer([:positive])}-#{name}"
    tmp_pack = Path.join(dir, tmp <> ".pack.tmp")
    tmp_idx = Path.join(dir, tmp <> ".idx.tmp")

    try do
      write_synced!(tmp_pack, encoded.pack)
      write_synced!(tmp_idx, idx_bin)

      with {:ok, index} <- Index.decode(idx_bin),
           :ok <- verify_pack_checksum(tmp_pack, encoded.checksum),
           :ok <- verify_pack(tmp_pack, index.offsets, objects),
           :ok <- rename_pack(tmp_pack, pack_path, tmp_idx, idx_path) do
        Cache.invalidate(repo.home_dir)

        {:ok,
         %{
           name: name,
           objects: length(objects),
           bytes: byte_size(encoded.pack),
           pack_path: pack_path,
           idx_path: idx_path
         }}
      end
    rescue
      error -> {:error, {:pack_write_failed, error}}
    after
      File.rm(tmp_pack)
      File.rm(tmp_idx)
    end
  end

  defp write_synced!(path, data) do
    {:ok, io} = File.open(path, [:write, :binary])

    try do
      :ok = IO.binwrite(io, data)
      :ok = :file.sync(io)
    after
      File.close(io)
    end
  end

  defp rename_pack(tmp_pack, pack_path, tmp_idx, idx_path) do
    # Pack first: readers discover packs through the idx, so an idx without its
    # pack can never be observed.
    with :ok <- File.rename(tmp_pack, pack_path),
         :ok <- File.rename(tmp_idx, idx_path) do
      :ok
    end
  end

  defp verify_pack_checksum(path, expected) do
    with {:ok, %File.Stat{size: size}} when size >= 20 <- File.stat(path),
         {:ok, trailer} <- read_tail(path, size),
         true <- trailer == expected,
         {:ok, digest} <- sha1_file(path, size - 20) do
      if digest == trailer, do: :ok, else: {:error, :pack_checksum_mismatch}
    else
      false -> {:error, :pack_checksum_mismatch}
      {:ok, _other} -> {:error, :truncated_pack}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_tail(path, size) do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        result = :file.pread(io, size - 20, 20)
        :file.close(io)

        case result do
          {:ok, trailer} when byte_size(trailer) == 20 -> {:ok, trailer}
          _ -> {:error, :truncated_pack}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sha1_file(path, length) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        result = hash_stream(io, length, :crypto.hash_init(:sha))
        File.close(io)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp hash_stream(_io, 0, context), do: {:ok, :crypto.hash_final(context)}

  defp hash_stream(io, remaining, context) do
    take = min(remaining, 1_048_576)

    case :file.read(io, take) do
      {:ok, data} when byte_size(data) == take ->
        hash_stream(io, remaining - take, :crypto.hash_update(context, data))

      _ ->
        {:error, :truncated_pack}
    end
  end

  defp verify_pack(tmp_pack, offsets, objects) do
    {:ok, %File.Stat{size: size}} = File.stat(tmp_pack)
    ends = Pack.entry_ends(offsets, size)

    Enum.reduce_while(objects, :ok, fn %{sha: sha, type: type, data: data}, :ok ->
      case Pack.read_object(tmp_pack, offsets, sha, ends: ends) do
        {:ok, {^type, ^data}} ->
          {:cont, :ok}

        {:ok, _other} ->
          {:halt, {:error, {:pack_verification_failed, sha}}}

        {:error, reason} ->
          {:halt, {:error, {:pack_verification_failed, sha, reason}}}
      end
    end)
  end

  defp normalize_objects(objects) do
    objects
    |> Enum.reduce_while({:ok, []}, fn %{type: type} = object, {:ok, acc} ->
      case normalize_type(type) do
        {:ok, normalized} -> {:cont, {:ok, [%{object | type: normalized} | acc]}}
        :error -> {:halt, {:error, {:invalid_type, type}}}
      end
    end)
    |> case do
      {:ok, objects} -> {:ok, Enum.reverse(objects)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp loose_in_dir(objects_dir, dir) do
    dir_path = Path.join(objects_dir, dir)

    case File.ls(dir_path) do
      {:ok, files} ->
        files
        |> Enum.filter(&Regex.match?(~r/^[0-9a-f]{38}$/, &1))
        |> Enum.flat_map(fn file ->
          path = Path.join(dir_path, file)

          case File.stat(path) do
            {:ok, %File.Stat{size: size}} -> [%{sha: dir <> file, size: size, path: path}]
            {:error, _reason} -> []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp valid_sha?(sha), do: is_binary(sha) and Regex.match?(~r/^[0-9a-f]{40}$/, sha)

  defp loose_object?(repo, sha) do
    <<dir::binary-size(2)>> <> rest = sha
    File.exists?(Path.join([repo.home_dir, "objects", dir, rest]))
  end

  defp packed_object?(repo, sha) do
    packed_in?(packs(repo), sha) or packed_in?(Cache.reload(repo.home_dir), sha)
  end

  defp packed_in?(packs, sha), do: Enum.any?(packs, &Map.has_key?(&1.offsets, sha))

  @doc """
  Materialize the tree referenced by `sha` into `dest` (created if needed).

  Files and directories present in the tree are written; files not present in
  the tree are left untouched (checkout is additive, not destructive).
  """
  @spec checkout(t(), sha(), Path.t()) :: :ok
  def checkout(repo, sha, dest) do
    commit = read_commit(repo, sha) || raise ArgumentError, "no commit at #{sha}"
    File.mkdir_p!(dest)
    materialize(repo, read_tree(repo, commit.tree) || [], dest)
    :ok
  end

  @doc """
  Compares two tree SHAs and returns the changed files between them.

  `old_tree` may be `nil` (treated as an empty tree, i.e. a root commit).
  Returns a list of change maps sorted by path:

      %{path: "src/foo.ex", status: :added, old_content: nil, new_content: "..."}

  `status` is `:added`, `:modified`, or `:deleted`; unmodified files are
  omitted. `old_content`/`new_content` are the decoded blob contents (or `nil`
  when the file is absent on that side). Content is compared by SHA, so
  unchanged files are skipped cheaply.
  """
  @spec diff_trees(t(), sha() | nil, sha()) :: [
          %{
            path: String.t(),
            status: :added | :modified | :deleted,
            old_content: binary() | nil,
            new_content: binary() | nil
          }
        ]
  def diff_trees(repo, old_tree, new_tree) do
    old = flatten_tree(repo, old_tree)
    new = flatten_tree(repo, new_tree)

    (Map.keys(old) ++ Map.keys(new))
    |> Enum.uniq()
    |> Enum.reduce([], fn path, acc ->
      change(old, new, repo, path, acc)
    end)
    |> Enum.sort_by(& &1.path)
  end

  ## Object traversal / import validation

  defp collect_objects(repo, sha, visited, acc) do
    if MapSet.member?(visited, sha) do
      {:ok, acc, visited}
    else
      case read_object(repo, sha) do
        nil ->
          {:error, :missing_object}

        {type, data} ->
          visited = MapSet.put(visited, sha)
          acc = [%{sha: sha, type: type, data: data} | acc]

          children =
            case type do
              :commit -> [%{ref: decode_commit(data, sha).tree}]
              :tree -> decode_tree(data) |> Enum.reject(&(&1.type == :commit))
              :blob -> []
            end

          collect_children(repo, children, visited, acc)
      end
    end
  end

  defp collect_children(repo, entries, visited, acc) do
    Enum.reduce_while(entries, {:ok, acc, visited}, fn
      %{ref: ref}, {:ok, acc, visited} ->
        case collect_objects(repo, ref, visited, acc) do
          {:ok, acc, visited} -> {:cont, {:ok, acc, visited}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end)
  end

  defp validate_objects(objects) do
    Enum.reduce_while(objects, :ok, fn object, :ok ->
      case validate_object(object) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_object(%{sha: sha, type: type, data: data})
       when is_binary(sha) and is_binary(data) do
    cond do
      not Regex.match?(~r/^[0-9a-f]{40}$/, sha) ->
        {:error, {:invalid_sha, sha}}

      true ->
        case normalize_type(type) do
          {:ok, normalized} ->
            cond do
              object_sha(normalized, data) != sha ->
                {:error, {:sha_mismatch, sha}}

              true ->
                case validate_payload(normalized, data) do
                  :ok -> :ok
                  {:error, reason} -> {:error, {:invalid_payload, sha, reason}}
                end
            end

          :error ->
            {:error, {:invalid_type, type}}
        end
    end
  end

  defp validate_object(other), do: {:error, {:invalid_object, other}}

  defp normalize_type(type) when type in [:blob, :tree, :commit], do: {:ok, type}

  defp normalize_type(type) when type in ["blob", "tree", "commit"],
    do: {:ok, String.to_existing_atom(type)}

  defp normalize_type(_type), do: :error

  defp object_sha(type, data) do
    header = [Atom.to_string(type), " ", Integer.to_string(byte_size(data)), <<0>>]

    :crypto.hash(:sha, IO.iodata_to_binary([header, data]))
    |> Base.encode16(case: :lower)
  end

  defp validate_payload(:blob, _data), do: :ok

  defp validate_payload(:tree, data) do
    try do
      Enum.reduce_while(decode_tree(data), :ok, fn entry, :ok ->
        cond do
          not safe_name?(entry.name) ->
            {:halt, {:error, :unsafe_tree_entry}}

          entry.mode not in [@dir_mode, @file_mode] ->
            {:halt, {:error, {:invalid_tree_mode, entry.mode}}}

          entry.type == :tree and entry.mode != @dir_mode ->
            {:halt, {:error, :invalid_tree_entry}}

          entry.type == :blob and entry.mode != @file_mode ->
            {:halt, {:error, :invalid_tree_entry}}

          true ->
            {:cont, :ok}
        end
      end)
    rescue
      _ -> {:error, :malformed_tree}
    catch
      _, _ -> {:error, :malformed_tree}
    end
  end

  defp validate_payload(:commit, data) do
    try do
      commit = decode_commit(data, String.duplicate("0", 40))

      cond do
        not sha?(commit.tree) ->
          {:error, :malformed_commit}

        not is_list(commit.parent) or not Enum.all?(commit.parent, &sha?/1) ->
          {:error, :malformed_commit}

        not is_map(commit.author) or not is_map(commit.committer) ->
          {:error, :malformed_commit}

        not is_binary(commit.message) ->
          {:error, :malformed_commit}

        true ->
          :ok
      end
    rescue
      _ -> {:error, :malformed_commit}
    catch
      _, _ -> {:error, :malformed_commit}
    end
  end

  defp sha?(sha), do: is_binary(sha) and Regex.match?(~r/^[0-9a-f]{40}$/, sha)

  ## Object storage

  defp write_object(repo, type, data) when is_binary(data) do
    header = [type, " ", Integer.to_string(byte_size(data)), <<0>>]
    bin = IO.iodata_to_binary([header, data])
    sha = :crypto.hash(:sha, bin) |> Base.encode16(case: :lower)

    dir = Path.join([repo.home_dir, "objects", binary_part(sha, 0, 2)])
    path = Path.join(dir, binary_part(sha, 2, byte_size(sha) - 2))

    File.mkdir_p!(dir)
    if not File.exists?(path), do: File.write!(path, :zlib.compress(bin))
    sha
  end

  # Loose first (the write path and the common read path), then packs. A
  # malformed or absent loose file falls through so a packed copy can answer.
  # The hex guard also keeps a non-SHA input from probing paths outside
  # `objects/` (`".." <> 37 chars` passes a byte-size check alone).
  defp read_object(repo, sha) when is_binary(sha) and byte_size(sha) == 40 do
    if valid_sha?(sha) do
      case read_loose_object(repo, sha) do
        {:ok, object} -> object
        _missing_or_corrupt -> read_packed_object(repo, sha)
      end
    end
  end

  defp read_object(_repo, _sha), do: nil

  defp read_loose_object(repo, <<dir::binary-size(2)>> <> rest) do
    path = Path.join([repo.home_dir, "objects", dir, rest])

    case File.read(path) do
      {:ok, compressed} ->
        case decode_object_file(compressed) do
          nil -> :corrupt
          object -> {:ok, object}
        end

      {:error, :enoent} ->
        :not_found

      {:error, _reason} ->
        :corrupt
    end
  end

  defp read_loose_object(_repo, _sha), do: :not_found

  defp read_packed_object(repo, sha) when is_binary(sha) and byte_size(sha) == 40 do
    case find_packed(packs(repo), sha) do
      nil ->
        # A manual repack or another server node may have written a pack since
        # this VM cached the store. Reload once before declaring a miss.
        find_packed(Cache.reload(repo.home_dir), sha)

      object ->
        object
    end
  end

  defp read_packed_object(_repo, _sha), do: nil

  defp find_packed(packs, sha) do
    Enum.find_value(packs, fn pack ->
      case Map.fetch(pack.offsets, sha) do
        {:ok, _offset} ->
          case Pack.read_object(pack.pack_path, pack.offsets, sha, ends: pack.ends) do
            {:ok, {type, data}} -> {type, data}
            {:error, _reason} -> nil
          end

        :error ->
          nil
      end
    end)
  end

  defp decode_object_file(compressed) do
    try do
      bin = :zlib.uncompress(compressed)

      case :binary.split(bin, <<0>>) do
        [header, data] -> decode_object_header(header, data)
        _ -> nil
      end
    rescue
      _ -> nil
    catch
      _, _ -> nil
    end
  end

  defp decode_object_header(header, data) do
    case String.split(header, " ", parts: 2) do
      [type, size] ->
        with {:ok, type} <- existing_object_type(type),
             {size, ""} <- Integer.parse(size),
             true <- size == byte_size(data) do
          {type, data}
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp existing_object_type("blob"), do: {:ok, :blob}
  defp existing_object_type("tree"), do: {:ok, :tree}
  defp existing_object_type("commit"), do: {:ok, :commit}
  defp existing_object_type("tag"), do: {:ok, :tag}
  defp existing_object_type(_type), do: :error

  ## Tree encoding

  defp encode_tree(entries) do
    entries
    |> Enum.sort_by(fn
      %{type: :tree, name: name} -> name <> "/"
      %{name: name} -> name
    end)
    |> Enum.map(fn %{mode: mode, name: name, ref: sha} ->
      [mode, ?\s, name, 0, Base.decode16!(sha, case: :lower)]
    end)
    |> IO.iodata_to_binary()
  end

  defp decode_tree(""), do: []

  defp decode_tree(bin) do
    [mode_name, <<sha::binary-size(20)>> <> rest] = String.split(bin, <<0>>, parts: 2)
    [mode, name] = String.split(mode_name, " ", parts: 2)

    type =
      cond do
        mode == @dir_mode -> :tree
        mode == @gitlink_mode -> :commit
        true -> :blob
      end

    [
      %{name: name, mode: mode, type: type, ref: Base.encode16(sha, case: :lower)}
      | decode_tree(rest)
    ]
  end

  ## Commit encoding

  defp encode_commit(%{
         tree: tree,
         parent: parents,
         author: author,
         committer: committer,
         message: message
       }) do
    timestamp = System.os_time(:second)

    [
      "tree #{tree}\n",
      Enum.map(parents, &"parent #{&1}\n"),
      "author #{encode_ident(author, timestamp)}\n",
      "committer #{encode_ident(committer, timestamp)}\n",
      "\n",
      message
    ]
    |> IO.iodata_to_binary()
  end

  defp encode_ident(%{name: name, email: email}, timestamp) do
    "#{name} <#{email}> #{timestamp} +0000"
  end

  defp decode_commit(bin, sha) do
    [headers, message] = String.split(bin, "\n\n", parts: 2)

    headers
    |> String.split("\n")
    |> Enum.reduce(%{hash: sha, parent: []}, fn line, acc ->
      [key, value] = String.split(line, " ", parts: 2)

      case key do
        "tree" -> Map.put(acc, :tree, value)
        "parent" -> Map.update(acc, :parent, [value], &[value | &1])
        "author" -> Map.put(acc, :author, decode_ident(value))
        "committer" -> Map.put(acc, :committer, decode_ident(value))
        _ -> acc
      end
    end)
    |> Map.update(:parent, [], &Enum.reverse/1)
    |> Map.put(:message, message)
  end

  defp decode_ident(value) do
    [_, name, email, timestamp, timezone] =
      Regex.run(~r/(.*) <([^><]*)> (\d+) ([+-]\d{4})/, value)

    %{name: name, email: email, timestamp: String.to_integer(timestamp), timezone: timezone}
  end

  ## Import helpers

  defp resolve_gitfile(root, dot_git) do
    with {:ok, contents} <- File.read(dot_git),
         [line | _] <- String.split(contents, "\n", trim: true),
         "gitdir:" <> raw <- String.trim(line),
         dir = raw |> String.trim() |> Path.expand(root),
         true <- repository_dir?(dir) do
      {:ok, %{kind: :worktree, path: root, git_dir: dir}}
    else
      _ -> {:error, :invalid_gitfile}
    end
  end

  defp repository_dir?(dir) do
    File.dir?(Path.join(dir, "objects")) and File.regular?(Path.join(dir, "HEAD"))
  end

  defp resolve_ref(_repo, _ref, depth) when depth > 8, do: :error

  defp resolve_ref(repo, "HEAD", depth) do
    case File.read(Path.join(repo.home_dir, "HEAD")) do
      {:ok, contents} ->
        case String.trim(contents) do
          "ref:" <> target -> resolve_ref(repo, String.trim(target), depth + 1)
          sha -> if valid_sha?(sha), do: {:ok, sha}, else: :error
        end

      _ ->
        :error
    end
  end

  defp resolve_ref(repo, ref, _depth) do
    if valid_ref_name?(ref) do
      case read_ref_file(Path.join(repo.home_dir, ref)) do
        {:ok, sha} -> {:ok, sha}
        :error -> read_packed_ref(repo, ref)
      end
    else
      :error
    end
  end

  defp read_ref_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        sha = String.trim(contents)
        if valid_sha?(sha), do: {:ok, sha}, else: :error

      _ ->
        :error
    end
  end

  defp read_packed_ref(repo, ref) do
    case File.read(Path.join(repo.home_dir, "packed-refs")) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.find_value(:error, fn line ->
          case String.split(String.trim(line), " ", parts: 2) do
            [sha, ^ref] -> if valid_sha?(sha), do: {:ok, sha}
            _ -> nil
          end
        end)

      _ ->
        :error
    end
  end

  defp valid_ref_name?("refs/" <> rest) when rest != "" do
    rest
    |> String.split("/")
    |> Enum.all?(fn segment ->
      segment not in ["", ".", ".."] and
        not String.contains?(segment, "\\") and
        not String.contains?(segment, <<0>>)
    end)
  end

  defp valid_ref_name?(_ref), do: false

  defp selected_ref?("refs/heads/" <> _rest), do: true
  defp selected_ref?("refs/tags/" <> _rest), do: true
  defp selected_ref?(_ref), do: false

  defp list_loose_refs(dir, prefix) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.reduce(names, %{}, fn name, acc ->
          path = Path.join(dir, name)
          ref = prefix <> "/" <> name

          # `lstat` keeps a symlinked ref directory from being followed (and
          # looping); regular ref files are still read.
          case File.lstat(path) do
            {:ok, %File.Stat{type: :directory}} ->
              Map.merge(acc, list_loose_refs(path, ref))

            {:ok, %File.Stat{type: :regular}} ->
              case read_ref_file(path) do
                {:ok, sha} -> if selected_ref?(ref), do: Map.put(acc, ref, sha), else: acc
                :error -> acc
              end

            _other ->
              acc
          end
        end)

      _ ->
        %{}
    end
  end

  defp read_packed_refs(repo) do
    case File.read(Path.join(repo.home_dir, "packed-refs")) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.reduce(%{}, fn line, acc ->
          line = String.trim(line)

          cond do
            String.starts_with?(line, "#") or String.starts_with?(line, "^") ->
              acc

            true ->
              case String.split(line, " ", parts: 2) do
                [sha, ref] ->
                  if valid_sha?(sha) and selected_ref?(ref) and valid_ref_name?(ref),
                    do: Map.put(acc, ref, sha),
                    else: acc

                _ ->
                  acc
              end
          end
        end)

      _ ->
        %{}
    end
  end

  defp measure_commit(repo, %{tree: tree}, max, acc) when is_binary(tree) do
    case measure_tree(repo, tree, "", max, acc, MapSet.new()) do
      {:ok, bytes, acc, _visited} -> {:ok, bytes, acc}
      {:error, reason} -> {:error, reason}
    end
  end

  defp measure_commit(_repo, _commit, _max, _acc), do: {:error, :invalid_commit}

  defp measure_tree(repo, tree_sha, prefix, max, acc, visited) do
    if MapSet.member?(visited, tree_sha) do
      {:ok, 0, acc, visited}
    else
      visited = MapSet.put(visited, tree_sha)

      case read_tree(repo, tree_sha) do
        nil ->
          {:error, {:missing_object, tree_sha}}

        entries ->
          entries
          |> Enum.sort_by(& &1.name)
          |> Enum.reduce_while({:ok, 0, acc, visited}, fn entry, {:ok, bytes, acc, visited} ->
            path = join_path(prefix, entry.name)

            case entry.type do
              :commit ->
                {:cont, {:ok, bytes, acc, visited}}

              :tree ->
                case measure_tree(repo, entry.ref, path, max, acc, visited) do
                  {:ok, sub_bytes, acc, visited} ->
                    {:cont, {:ok, bytes + sub_bytes, acc, visited}}

                  {:error, reason} ->
                    {:halt, {:error, reason}}
                end

              :blob ->
                case blob_size(repo, entry.ref, acc) do
                  {:ok, size, acc} when max == :infinity or size <= max ->
                    {:cont, {:ok, bytes + size, acc, visited}}

                  {:ok, size, _acc} ->
                    {:halt, {:error, {:blob_too_large, path, size}}}

                  {:error, reason} ->
                    {:halt, {:error, reason}}
                end
            end
          end)
      end
    end
  end

  defp blob_size(repo, sha, acc) do
    case Map.fetch(acc.sizes, sha) do
      {:ok, size} ->
        {:ok, size, acc}

      :error ->
        case read_blob(repo, sha) do
          nil ->
            {:error, {:missing_object, sha}}

          data ->
            size = byte_size(data)

            {:ok, size,
             %{
               acc
               | sizes: Map.put(acc.sizes, sha, size),
                 blobs: acc.blobs + 1,
                 bytes: acc.bytes + size
             }}
        end
    end
  end

  defp peel_to_commit(repo, sha, depth \\ 0)
  defp peel_to_commit(_repo, _sha, depth) when depth > 8, do: {:error, :tag_chain_too_deep}

  defp peel_to_commit(repo, sha, depth) do
    case read_commit(repo, sha) do
      %{hash: ^sha} ->
        {:ok, sha}

      nil ->
        case read_object(repo, sha) do
          {:tag, data} ->
            case tag_target(data) do
              {:ok, target} -> peel_to_commit(repo, target, depth + 1)
              :error -> {:error, :not_a_commit}
            end

          {_type, _data} ->
            {:error, :not_a_commit}

          nil ->
            {:error, :not_found}
        end
    end
  end

  defp tag_target(data) do
    data
    |> String.split("\n\n", parts: 2)
    |> hd()
    |> String.split("\n")
    |> Enum.find_value(:error, fn line ->
      case String.split(line, " ", parts: 2) do
        ["object", sha] -> if valid_sha?(sha), do: {:ok, sha}
        _ -> nil
      end
    end)
  end

  defp collect_commits(repo, queue, seen, max, truncate?, shallow, acc) do
    case :queue.out(queue) do
      {:empty, _} ->
        {:ok, acc}

      {{:value, sha}, queue} ->
        cond do
          MapSet.member?(seen, sha) ->
            collect_commits(repo, queue, seen, max, truncate?, shallow, acc)

          map_size(acc.commits) >= max and truncate? ->
            {:ok, %{acc | truncated: true}}

          map_size(acc.commits) >= max ->
            {:error, {:too_many_commits, max}}

          true ->
            case read_commit(repo, sha) do
              nil ->
                {:error, {:missing_object, sha}}

              commit ->
                boundary? = MapSet.member?(shallow, sha) and commit.parent != []
                parents = if boundary?, do: [], else: commit.parent
                queue = Enum.reduce(parents, queue, fn parent, q -> :queue.in(parent, q) end)

                acc = %{
                  acc
                  | commits: Map.put(acc.commits, sha, commit),
                    shallow: acc.shallow or boundary?
                }

                collect_commits(repo, queue, MapSet.put(seen, sha), max, truncate?, shallow, acc)
            end
        end
    end
  end

  defp sort_commits(commits) when map_size(commits) == 0, do: {:ok, []}

  defp sort_commits(commits) do
    parents =
      Map.new(commits, fn {sha, commit} ->
        {sha, Enum.filter(commit.parent, &Map.has_key?(commits, &1))}
      end)

    indegree = Map.new(parents, fn {sha, ps} -> {sha, length(ps)} end)

    children =
      Enum.reduce(parents, %{}, fn {sha, ps}, acc ->
        Enum.reduce(ps, acc, fn parent, acc2 ->
          Map.update(acc2, parent, [sha], &[sha | &1])
        end)
      end)

    ready =
      commits
      |> Map.values()
      |> Enum.filter(&(indegree[&1.hash] == 0))
      |> Enum.map(&sort_key/1)
      |> :gb_sets.from_list()

    drain_commits(ready, indegree, children, commits, [])
  end

  defp drain_commits(ready, indegree, children, commits, acc) do
    if :gb_sets.is_empty(ready) do
      if length(acc) == map_size(commits), do: {:ok, Enum.reverse(acc)}, else: {:error, :cycle}
    else
      {key, ready} = :gb_sets.take_smallest(ready)
      sha = elem(key, 1)
      commit = Map.fetch!(commits, sha)

      {indegree, ready} =
        Enum.reduce(Map.get(children, sha, []), {indegree, ready}, fn child, {indegree, ready} ->
          remaining = Map.fetch!(indegree, child) - 1
          indegree = Map.put(indegree, child, remaining)

          ready =
            if remaining == 0 do
              :gb_sets.add(sort_key(Map.fetch!(commits, child)), ready)
            else
              ready
            end

          {indegree, ready}
        end)

      drain_commits(ready, indegree, children, commits, [commit | acc])
    end
  end

  defp sort_key(commit) do
    timestamp =
      case commit.author do
        %{timestamp: ts} when is_integer(ts) -> ts
        _ -> 0
      end

    {timestamp, commit.hash}
  end

  defp commit_target(source, %{hash: sha, tree: tree})
       when is_binary(sha) and is_binary(tree) do
    case read_raw(source, sha) do
      {:ok, {:commit, _data}} -> {:ok, sha, tree}
      {:ok, _other} -> {:error, {:not_a_commit, sha}}
      {:error, :not_found} -> {:error, {:missing_object, sha}}
    end
  end

  defp commit_target(source, sha) when is_binary(sha) do
    case read_commit(source, sha) do
      %{tree: tree} -> {:ok, sha, tree}
      nil -> {:error, {:missing_object, sha}}
    end
  end

  defp commit_target(_source, _other), do: {:error, :invalid_commit}

  defp copy_commit(source, target, sha, acc) do
    case read_raw(source, sha) do
      {:ok, {:commit, data}} ->
        write_object_counted(target, :commit, data, sha, acc)

      {:ok, _other} ->
        {:error, {:not_a_commit, sha}}

      {:error, :not_found} ->
        {:error, {:missing_object, sha}}
    end
  end

  defp copy_tree(source, target, sha, acc) do
    if MapSet.member?(acc.trees, sha) do
      {:ok, acc}
    else
      case read_raw(source, sha) do
        {:ok, {:tree, data}} ->
          with {:ok, acc} <- write_object_counted(target, :tree, data, sha, acc) do
            acc = %{acc | trees: MapSet.put(acc.trees, sha)}

            data
            |> decode_tree()
            |> Enum.reduce_while({:ok, acc}, fn entry, {:ok, acc} ->
              case copy_entry(source, target, entry, acc) do
                {:ok, acc} -> {:cont, {:ok, acc}}
                {:error, reason} -> {:halt, {:error, reason}}
              end
            end)
          end

        {:ok, _other} ->
          {:error, {:not_a_tree, sha}}

        {:error, :not_found} ->
          {:error, {:missing_object, sha}}
      end
    end
  end

  # A submodule (gitlink, mode 160000) points at a commit in another
  # repository; it stays an entry in the imported tree but its object is not
  # copied here.
  defp copy_entry(_source, _target, %{mode: "160000"}, acc), do: {:ok, acc}

  defp copy_entry(source, target, %{type: :tree, ref: sha}, acc) do
    copy_tree(source, target, sha, acc)
  end

  defp copy_entry(source, target, %{type: :blob, ref: sha}, acc) do
    case read_raw(source, sha) do
      {:ok, {:blob, data}} ->
        if acc.max_blob != :infinity and byte_size(data) > acc.max_blob do
          {:error, {:blob_too_large, sha, byte_size(data)}}
        else
          write_object_counted(target, :blob, data, sha, acc)
        end

      {:ok, _other} ->
        {:error, {:not_a_blob, sha}}

      {:error, :not_found} ->
        {:error, {:missing_object, sha}}
    end
  end

  # The copy is the only writer of `target` while it runs, so `present_shas/2`
  # (loose file + cached pack indexes) is enough; `has_object?/2` would reload
  # the pack cache on every miss, once per copied object.
  defp write_object_counted(target, type, data, expected, acc) do
    if MapSet.member?(acc.written, expected) or present_shas(target, [expected]) != [] do
      {:ok, %{acc | written: MapSet.put(acc.written, expected)}}
    else
      case write_raw(target, type, data) do
        ^expected ->
          {:ok,
           %{
             acc
             | objects: acc.objects + 1,
               bytes: acc.bytes + byte_size(data),
               written: MapSet.put(acc.written, expected)
           }}

        _other ->
          {:error, {:hash_mismatch, expected}}
      end
    end
  end

  ## Checkout

  defp materialize(repo, entries, dir) do
    Enum.each(entries, fn
      %{type: :tree, name: name, ref: ref} ->
        sub = join_safely(dir, name)
        File.mkdir_p!(sub)
        materialize(repo, read_tree(repo, ref) || [], sub)

      %{type: :blob, name: name, ref: ref} ->
        File.write!(join_safely(dir, name), read_blob(repo, ref))
    end)
  end

  # Rejects tree entry names that could escape `dir` (path traversal). Names
  # produced by `build_tree/2` are always safe (single `File.ls!` components),
  # but trees pulled from an untrusted source must be guarded before use.
  defp join_safely(dir, name) do
    if safe_name?(name) do
      Path.join(dir, name)
    else
      raise ArgumentError, "unsafe tree entry name: #{inspect(name)}"
    end
  end

  defp safe_name?(name) do
    is_binary(name) and
      name not in [".", ".."] and
      not String.contains?(name, ["/", "\\"]) and
      Path.type(name) != :absolute
  end

  ## Tree diff

  defp change(old, new, repo, path, acc) do
    old_ref = Map.get(old, path)
    new_ref = Map.get(new, path)

    cond do
      old_ref == nil ->
        [
          %{path: path, status: :added, old_content: nil, new_content: read_blob(repo, new_ref)}
          | acc
        ]

      new_ref == nil ->
        [
          %{path: path, status: :deleted, old_content: read_blob(repo, old_ref), new_content: nil}
          | acc
        ]

      old_ref == new_ref ->
        acc

      true ->
        [
          %{
            path: path,
            status: :modified,
            old_content: read_blob(repo, old_ref),
            new_content: read_blob(repo, new_ref)
          }
          | acc
        ]
    end
  end

  defp flatten_tree(_repo, nil), do: %{}

  defp flatten_tree(repo, sha) do
    case read_tree(repo, sha) do
      nil ->
        raise ArgumentError, "missing tree object #{sha}"

      entries ->
        Enum.reduce(entries, %{}, fn
          %{type: :blob, name: name, ref: ref}, acc ->
            Map.put(acc, name, ref)

          %{type: :tree, name: name, ref: ref}, acc ->
            sub = flatten_tree(repo, ref) |> prefix_keys(name)
            Map.merge(acc, sub)
        end)
    end
  end

  defp prefix_keys(map, prefix) do
    Map.new(map, fn {path, ref} -> {"#{prefix}/#{path}", ref} end)
  end
end
