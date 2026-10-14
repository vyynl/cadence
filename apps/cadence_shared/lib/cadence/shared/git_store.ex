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
      |> Enum.flat_map(fn name ->
        path = Path.join(dir, name)

        if ignored?(name, ignore) do
          []
        else
          case File.lstat!(path).type do
            :directory ->
              [%{name: name, mode: @dir_mode, type: :tree, ref: build_tree(repo, path, opts)}]

            :regular ->
              [
                %{
                  name: name,
                  mode: @file_mode,
                  type: :blob,
                  ref: write_blob(repo, File.read!(path))
                }
              ]

            _ ->
              []
          end
        end
      end)

    write_tree(repo, entries)
  end

  defp ignored?(name, ignore), do: name in @always_ignored or name in ignore

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
        bin = :zlib.uncompress(compressed)
        [header, data] = String.split(bin, <<0>>, parts: 2)
        [type, _size] = String.split(header, " ", parts: 2)
        {String.to_atom(type), data}

      {:error, :enoent} ->
        nil
    end
  end

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
    repo
    |> read_tree(sha)
    |> Enum.reduce(%{}, fn
      %{type: :blob, name: name, ref: ref}, acc ->
        Map.put(acc, name, ref)

      %{type: :tree, name: name, ref: ref}, acc ->
        sub = flatten_tree(repo, ref) |> prefix_keys(name)
        Map.merge(acc, sub)
    end)
  end

  defp prefix_keys(map, prefix) do
    Map.new(map, fn {path, ref} -> {"#{prefix}/#{path}", ref} end)
  end
end
