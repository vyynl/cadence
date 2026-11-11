defmodule Cadence.Shared.GitImportTest do
  use ExUnit.Case, async: true

  alias Cadence.Shared.GitStore

  @file_mode "100644"
  @gitlink_mode "160000"

  setup do
    root = Path.join(System.tmp_dir!(), "cadence_import_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  describe "detect_repository/1" do
    test "detects a bare repository", %{root: root} do
      repo = bare(root, "bare")

      assert {:ok, %{kind: :bare, git_dir: git_dir}} = GitStore.detect_repository(repo.home_dir)
      assert git_dir == repo.home_dir
    end

    test "detects a worktree and a .git redirect file", %{root: root} do
      bare_repo = bare(root, "objects")

      work = Path.join(root, "work")
      File.mkdir_p!(Path.join(work, ".git/objects"))
      File.write!(Path.join(work, ".git/HEAD"), "ref: refs/heads/main\n")

      assert {:ok, %{kind: :worktree, git_dir: git_dir}} = GitStore.detect_repository(work)
      assert git_dir == Path.join(work, ".git")

      redirect = Path.join(root, "redirect")
      File.mkdir_p!(redirect)
      File.write!(Path.join(redirect, ".git"), "gitdir: #{bare_repo.home_dir}\n")

      assert {:ok, %{kind: :worktree, git_dir: redirected}} =
               GitStore.detect_repository(redirect)

      assert redirected == bare_repo.home_dir
    end

    test "rejects a plain directory and a broken redirect", %{root: root} do
      assert {:error, :not_a_repository} = GitStore.detect_repository(root)

      broken = Path.join(root, "broken")
      File.mkdir_p!(broken)
      File.write!(Path.join(broken, ".git"), "gitdir: /does/not/exist\n")

      assert {:error, :invalid_gitfile} = GitStore.detect_repository(broken)
    end
  end

  describe "read_ref/2" do
    test "reads HEAD, loose refs, and packed refs, with loose winning", %{root: root} do
      repo = bare(root, "refs")
      old = commit(repo, tree(repo, "a", "1"), [], "old")
      tip = commit(repo, tree(repo, "a", "2"), [old], "tip")

      write_head(repo, "ref: refs/heads/main")
      write_ref(repo, "refs/heads/main", tip)
      write_ref(repo, "refs/tags/v1", old)
      write_packed_refs(repo, [{old, "refs/heads/main"}, {old, "refs/heads/old"}])

      assert {:ok, ^tip} = GitStore.read_ref(repo, "HEAD")
      assert {:ok, ^tip} = GitStore.read_ref(repo, "refs/heads/main")
      assert {:ok, ^old} = GitStore.read_ref(repo, "refs/tags/v1")
      assert {:ok, ^old} = GitStore.read_ref(repo, "refs/heads/old")
      assert {:error, :not_found} = GitStore.read_ref(repo, "refs/heads/missing")
      assert {:error, :not_found} = GitStore.read_ref(repo, "../HEAD")
    end

    test "reads a detached HEAD", %{root: root} do
      repo = bare(root, "detached")
      sha = commit(repo, tree(repo, "a", "1"), [], "one")
      write_head(repo, sha)

      assert {:ok, ^sha} = GitStore.read_ref(repo, "HEAD")
    end
  end

  describe "resolve_revision/2" do
    test "resolves branches, tags, HEAD, SHAs, and peels annotated tags", %{root: root} do
      repo = bare(root, "resolve")
      sha = commit(repo, tree(repo, "a", "1"), [], "one")

      write_head(repo, "ref: refs/heads/main")
      write_ref(repo, "refs/heads/main", sha)
      write_ref(repo, "refs/tags/light", sha)

      annotated =
        GitStore.write_raw(
          repo,
          :tag,
          "object #{sha}\ntype commit\ntag v1\ntagger A <a@example.com> 1700000000 +0000\n\nrelease\n"
        )

      write_ref(repo, "refs/tags/annotated", annotated)

      assert {:ok, ^sha} = GitStore.resolve_revision(repo, "main")
      assert {:ok, ^sha} = GitStore.resolve_revision(repo, "refs/heads/main")
      assert {:ok, ^sha} = GitStore.resolve_revision(repo, "light")
      assert {:ok, ^sha} = GitStore.resolve_revision(repo, "annotated")
      assert {:ok, ^sha} = GitStore.resolve_revision(repo, "refs/tags/annotated")
      assert {:ok, ^sha} = GitStore.resolve_revision(repo, "HEAD")
      assert {:ok, ^sha} = GitStore.resolve_revision(repo, sha)
      assert {:error, :not_found} = GitStore.resolve_revision(repo, "missing")
    end

    test "refuses a tag or SHA that is not a commit", %{root: root} do
      repo = bare(root, "not_commit")
      blob = GitStore.write_blob(repo, "not a commit")
      tag = GitStore.write_raw(repo, :tag, "object #{blob}\ntype blob\ntag blob\n\nx\n")
      write_ref(repo, "refs/tags/blob", tag)

      assert {:error, :not_a_commit} = GitStore.resolve_revision(repo, "blob")
      assert {:error, :not_a_commit} = GitStore.resolve_revision(repo, blob)
    end
  end

  describe "walk_commits/3" do
    test "returns a linear history parents-first", %{root: root} do
      repo = bare(root, "linear")
      root_commit = commit(repo, tree(repo, "a", "1"), [], "root", 100)
      second = commit(repo, tree(repo, "b", "2"), [root_commit], "second", 200)
      third = commit(repo, tree(repo, "c", "3"), [second], "third", 300)

      assert {:ok, %{commits: commits, truncated: false, shallow: false}} =
               GitStore.walk_commits(repo, [third])

      assert Enum.map(commits, & &1.hash) == [root_commit, second, third]
      assert Enum.map(commits, &String.trim(&1.message)) == ["root", "second", "third"]
    end

    test "keeps a merge's parents before the merge", %{root: root} do
      repo = bare(root, "merge")
      root_commit = commit(repo, tree(repo, "a", "1"), [], "root", 100)
      left = commit(repo, tree(repo, "b", "2"), [root_commit], "left", 200)
      right = commit(repo, tree(repo, "c", "3"), [root_commit], "right", 300)
      merge = commit(repo, tree(repo, "d", "4"), [left, right], "merge", 400)

      assert {:ok, %{commits: commits}} = GitStore.walk_commits(repo, [merge])
      hashes = Enum.map(commits, & &1.hash)

      assert List.last(hashes) == merge
      assert index(hashes, root_commit) < index(hashes, left)
      assert index(hashes, root_commit) < index(hashes, right)
      assert index(hashes, left) < index(hashes, merge)
      assert index(hashes, right) < index(hashes, merge)
    end

    test "stops at a shallow boundary and reports it", %{root: root} do
      repo = bare(root, "shallow")
      missing = String.duplicate("0", 39) <> "1"
      boundary = commit(repo, tree(repo, "a", "1"), [missing], "boundary", 200)
      File.write!(Path.join(repo.home_dir, "shallow"), boundary <> "\n")

      assert {:ok, %{commits: [only], truncated: false, shallow: true}} =
               GitStore.walk_commits(repo, [boundary])

      assert only.hash == boundary

      File.rm!(Path.join(repo.home_dir, "shallow"))
      assert {:error, {:missing_object, ^missing}} = GitStore.walk_commits(repo, [boundary])
    end

    test "enforces the cap unless truncation is explicit", %{root: root} do
      repo = bare(root, "cap")
      one = commit(repo, tree(repo, "a", "1"), [], "one", 100)
      two = commit(repo, tree(repo, "b", "2"), [one], "two", 200)
      three = commit(repo, tree(repo, "c", "3"), [two], "three", 300)

      assert {:error, {:too_many_commits, 2}} = GitStore.walk_commits(repo, [three], max: 2)

      assert {:ok, %{commits: commits, truncated: true}} =
               GitStore.walk_commits(repo, [three], max: 2, truncate: true)

      assert length(commits) == 2
      assert List.last(commits).hash == three
    end

    test "returns an error for an unknown tip", %{root: root} do
      repo = bare(root, "unknown")
      unknown = String.duplicate("f", 40)

      assert {:error, {:missing_object, ^unknown}} = GitStore.walk_commits(repo, [unknown])
    end
  end

  describe "list_refs/1" do
    test "lists local branches and tags, with loose refs winning over packed", %{root: root} do
      repo = bare(root, "list_refs")
      one = commit(repo, tree(repo, "a", "1"), [], "one")
      two = commit(repo, tree(repo, "b", "2"), [one], "two")

      write_ref(repo, "refs/heads/main", two)
      write_ref(repo, "refs/tags/v1", one)
      write_ref(repo, "refs/remotes/origin/main", one)

      packed = Path.join(repo.home_dir, "packed-refs")

      File.write!(packed, """
      # pack-refs with: peeled fully-peeled sorted
      #{one} refs/heads/main
      #{two} refs/heads/other
      #{one} refs/tags/v1
      ^#{one}
      not-a-sha refs/heads/broken
      """)

      assert {:ok, refs} = GitStore.list_refs(repo)

      assert refs == [
               %{name: "refs/heads/main", sha: two},
               %{name: "refs/heads/other", sha: two},
               %{name: "refs/tags/v1", sha: one}
             ]
    end

    test "returns an empty list for a repository with no refs", %{root: root} do
      repo = bare(root, "no_refs")
      assert {:ok, []} = GitStore.list_refs(repo)
    end

    test "ignores a symlinked ref directory instead of following it", %{root: root} do
      repo = bare(root, "symlink_refs")
      sha = commit(repo, tree(repo, "a", "1"), [], "one")
      write_ref(repo, "refs/heads/main", sha)

      loop = Path.join([repo.home_dir, "refs", "loop"])
      File.mkdir_p!(loop)
      File.ln_s!(Path.join(repo.home_dir, "refs"), Path.join(loop, "back"))

      assert {:ok, [%{name: "refs/heads/main", sha: ^sha}]} = GitStore.list_refs(repo)
    end
  end

  describe "preflight_blobs/3" do
    test "counts unique blobs once and estimates the largest per-commit tree", %{root: root} do
      repo = bare(root, "preflight")
      readme = GitStore.write_blob(repo, "hello")
      added = GitStore.write_blob(repo, "world")

      first_tree =
        GitStore.write_tree(repo, [
          %{name: "README.md", mode: @file_mode, type: :blob, ref: readme}
        ])

      second_tree =
        GitStore.write_tree(repo, [
          %{name: "README.md", mode: @file_mode, type: :blob, ref: readme},
          %{name: "new.txt", mode: @file_mode, type: :blob, ref: added}
        ])

      first = commit(repo, first_tree, [], "one", 100)
      second = commit(repo, second_tree, [first], "two", 200)

      assert {:ok, %{commits: commits}} = GitStore.walk_commits(repo, [second])

      assert {:ok, %{blobs: 2, bytes: 10, largest_node_bytes: 10}} =
               GitStore.preflight_blobs(repo, commits)
    end

    test "rejects a blob above the limit with its path", %{root: root} do
      repo = bare(root, "preflight_big")
      big = GitStore.write_blob(repo, String.duplicate("x", 100))

      tree =
        GitStore.write_tree(repo, [
          %{name: "big.bin", mode: @file_mode, type: :blob, ref: big}
        ])

      sha = commit(repo, tree, [], "big", 100)
      assert {:ok, %{commits: [only]}} = GitStore.walk_commits(repo, [sha])

      assert {:error, {:blob_too_large, "big.bin", 100}} =
               GitStore.preflight_blobs(repo, [only], max_blob_bytes: 10)

      assert {:ok, _summary} = GitStore.preflight_blobs(repo, [only], max_blob_bytes: 0)
    end
  end

  describe "copy_commit_objects/4" do
    test "copies commits and their closure, skipping shared trees and gitlinks", %{root: root} do
      source = bare(root, "source")
      target = bare(root, "target")

      readme = GitStore.write_blob(source, "hello")

      first_tree =
        GitStore.write_tree(source, [
          %{name: "README.md", mode: @file_mode, type: :blob, ref: readme}
        ])

      first = commit(source, first_tree, [], "one", 100)
      added = GitStore.write_blob(source, "world")
      gitlink = String.duplicate("a", 40)

      second_tree =
        GitStore.write_tree(source, [
          %{name: "README.md", mode: @file_mode, type: :blob, ref: readme},
          %{name: "new.txt", mode: @file_mode, type: :blob, ref: added},
          %{name: "vendor", mode: @gitlink_mode, type: :blob, ref: gitlink}
        ])

      second = commit(source, second_tree, [first], "two", 200)

      assert {:ok, %{objects: objects, bytes: bytes}} =
               GitStore.copy_commit_objects(source, target, [first, second])

      assert objects > 0
      assert bytes > 0
      assert GitStore.has_object?(target, first)
      assert GitStore.has_object?(target, second)
      assert {:ok, _objects} = GitStore.objects_from(target, second)
      assert {:ok, "hello"} = GitStore.read_path(target, second, "README.md")
      assert {:ok, "world"} = GitStore.read_path(target, second, "new.txt")
      assert {:error, :not_a_file} = GitStore.read_path(target, second, "vendor")
      refute GitStore.has_object?(target, gitlink)

      assert {:ok, %{objects: 0}} =
               GitStore.copy_commit_objects(source, target, [first, second])

      # A destination that already holds a closure in a pack is skipped too.
      # (`first` is packed rather than `second` because a tree carrying a
      # gitlink is not a packable object set.)
      assert {:ok, first_objects} = GitStore.objects_from(target, first)
      assert {:ok, _pack} = GitStore.pack_objects(target, first_objects)

      Enum.each(first_objects, fn %{sha: sha} ->
        File.rm!(
          Path.join([target.home_dir, "objects", binary_part(sha, 0, 2), binary_part(sha, 2, 38)])
        )
      end)

      GitStore.invalidate_cache(target)

      assert {:ok, %{objects: 0}} =
               GitStore.copy_commit_objects(source, target, [first])
    end

    test "refuses a blob above the configured limit", %{root: root} do
      source = bare(root, "big_source")
      target = bare(root, "big_target")
      big = GitStore.write_blob(source, String.duplicate("x", 100))

      tree =
        GitStore.write_tree(source, [
          %{name: "big.bin", mode: @file_mode, type: :blob, ref: big}
        ])

      commit = commit(source, tree, [], "big", 100)

      assert {:error, {:blob_too_large, ^big, 100}} =
               GitStore.copy_commit_objects(source, target, [commit], max_blob_bytes: 10)

      refute GitStore.has_object?(target, big)
    end
  end

  defp bare(root, name) do
    repo = GitStore.init(Path.join(root, name), bare: true)
    File.write!(Path.join(repo.home_dir, "HEAD"), "ref: refs/heads/main\n")
    repo
  end

  defp tree(repo, name, content) do
    blob = GitStore.write_blob(repo, content)

    GitStore.write_tree(repo, [
      %{name: name, mode: @file_mode, type: :blob, ref: blob}
    ])
  end

  defp commit(repo, tree, parents, message, timestamp \\ 1_700_000_000) do
    ident = "A U Thor <a@example.com> #{timestamp} +0000"

    data =
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

    GitStore.write_raw(repo, :commit, data)
  end

  defp write_head(repo, target) do
    File.write!(Path.join(repo.home_dir, "HEAD"), target <> "\n")
  end

  defp write_ref(repo, ref, sha) do
    path = Path.join(repo.home_dir, ref)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, sha <> "\n")
  end

  defp write_packed_refs(repo, refs) do
    body =
      ["# pack-refs with: peeled fully-peeled sorted"]
      |> Kernel.++(Enum.map(refs, fn {sha, ref} -> "#{sha} #{ref}" end))
      |> Enum.join("\n")

    File.write!(Path.join(repo.home_dir, "packed-refs"), body <> "\n")
  end

  defp index(list, value) do
    Enum.find_index(list, &(&1 == value)) ||
      flunk("expected #{value} in #{inspect(list)}")
  end
end
