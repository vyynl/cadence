defmodule Cadence.Shared.GitStore do
  @moduledoc """
  A content-addressed Git object store (blob/tree/commit), specialized for
  Cadence's DAG-of-session-nodes model.

  Cadence has no branches, refs, tags, or packfiles: every session is an
  immutable commit addressed by its SHA, and parent links live in the `Node`
  schema rather than in the object store. This module therefore implements only
  the object layer, with a ref-less commit writer and no history/ref machinery.

  The Git object format (blob/tree/commit byte layout, SHA-1 content
  addressing, zlib compression) is a public standard. The encoding approach is
  derived from the pure-Elixir implementation in `awetzel/gitex` (MIT), which
  served as a reference for serializing those objects.
  """

  @type t :: %__MODULE__{home_dir: Path.t()}
  @type sha :: String.t()
  @type author :: %{name: String.t(), email: String.t()}
  @type entry :: %{name: String.t(), mode: String.t(), type: :blob | :tree, ref: sha()}
  @type object :: %{sha: sha(), type: :blob | :tree | :commit, data: binary()}
  @type commit :: %{
          hash: sha(),
          tree: sha(),
          parent: [sha()],
          author: author(),
          committer: author(),
          message: String.t()
        }

  @dir_mode "40000"
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

      nil ->
        {:error, :not_found}
    end
  end

  defp read_path_segments(repo, tree_sha, [name | rest], max_bytes) do
    case find_entry(repo, tree_sha, name) do
      %{type: :tree, ref: ref} -> read_path_segments(repo, ref, rest, max_bytes)
      %{type: :blob} -> {:error, :not_found}
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
        walk_tree_blobs(repo, commit.tree, "", max_files, max_bytes, [], 0, 0)

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
        |> case do
          {:ok, acc, _count, _bytes} -> {:ok, Enum.sort_by(acc, & &1.path)}
          error -> error
        end
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
  @spec write_raw(t(), :blob | :tree | :commit, binary()) :: sha()
  def write_raw(repo, type, data) when type in [:blob, :tree, :commit] and is_binary(data) do
    write_object(repo, Atom.to_string(type), data)
  end

  @doc "Return whether an object exists in the store."
  @spec has_object?(t(), sha()) :: boolean()
  def has_object?(repo, sha) when is_binary(sha) and byte_size(sha) == 40 do
    <<dir::binary-size(2)>> <> rest = sha
    File.exists?(Path.join([repo.home_dir, "objects", dir, rest]))
  end

  def has_object?(_repo, _sha), do: false

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
              :tree -> decode_tree(data)
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

  defp read_object(repo, <<dir::binary-size(2)>> <> rest) do
    path = Path.join([repo.home_dir, "objects", dir, rest])

    case File.read(path) do
      {:ok, compressed} ->
        decode_object_file(compressed)

      {:error, _reason} ->
        nil
    end
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
    type = if mode == @dir_mode, do: :tree, else: :blob

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
