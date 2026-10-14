defmodule Cadence.Shared.GitStoreTest do
  use ExUnit.Case, async: true

  alias Cadence.Shared.GitStore

  setup do
    dir = Path.join(System.tmp_dir!(), "cadence_gitstore_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, repo: GitStore.init(dir, bare: true)}
  end

  describe "init/2" do
    test "creates the objects directory", %{repo: repo} do
      assert File.dir?(Path.join(repo.home_dir, "objects"))
    end

    test "bare store uses the path directly", %{dir: dir, repo: repo} do
      assert repo.home_dir == Path.expand(dir)
    end

    test "non-bare store nests objects under .git", %{dir: dir} do
      repo = GitStore.init(dir)
      assert repo.home_dir == Path.expand(Path.join(dir, ".git"))
    end

    test "open/2 resolves the same path without creating anything", %{dir: dir} do
      missing = Path.join(dir, "absent")
      repo = GitStore.open(missing, bare: true)

      assert repo.home_dir == Path.expand(missing)
      refute File.exists?(repo.home_dir)
    end
  end

  describe "blob" do
    test "write/read round-trip", %{repo: repo} do
      sha = GitStore.write_blob(repo, "hello world\n")
      assert GitStore.read_blob(repo, sha) == "hello world\n"
    end

    test "produces the canonical git SHA for known content", %{repo: repo} do
      assert GitStore.write_blob(repo, "hello world\n") ==
               "3b18e512dba79e4c8300dd08aeb37f8e728b8dad"
    end

    test "is content-addressed and idempotent", %{repo: repo} do
      a = GitStore.write_blob(repo, "same content")
      b = GitStore.write_blob(repo, "same content")
      assert a == b
    end

    test "read_blob returns nil for a missing object", %{repo: repo} do
      assert GitStore.read_blob(repo, String.duplicate("0", 40)) == nil
    end
  end

  describe "tree" do
    test "empty tree matches git's canonical empty-tree SHA", %{repo: repo} do
      assert GitStore.write_tree(repo, []) == "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    end

    test "write/read round-trip", %{repo: repo} do
      blob = GitStore.write_blob(repo, "hi")

      sha =
        GitStore.write_tree(repo, [%{name: "a.txt", mode: "100644", type: :blob, ref: blob}])

      assert GitStore.read_tree(repo, sha) == [
               %{name: "a.txt", mode: "100644", type: :blob, ref: blob}
             ]
    end

    test "sorts directories by name with trailing slash", %{repo: repo} do
      dir_blob = GitStore.write_blob(repo, "dir")
      file_blob = GitStore.write_blob(repo, "file")

      entries = [
        %{name: "z", mode: "100644", type: :blob, ref: file_blob},
        %{name: "a", mode: "40000", type: :tree, ref: dir_blob}
      ]

      sha = GitStore.write_tree(repo, entries)
      assert [%{name: "a"}, %{name: "z"}] = GitStore.read_tree(repo, sha)
    end
  end

  describe "build_tree/2" do
    test "hashes a directory tree and round-trips via read_tree", %{dir: dir, repo: repo} do
      path = Path.join(dir, "src")
      File.mkdir_p!(Path.join(path, "nested"))
      File.write!(Path.join(path, "a.txt"), "top\n")
      File.write!(Path.join(path, "nested/b.txt"), "nested\n")

      sha = GitStore.build_tree(repo, path)
      entries = GitStore.read_tree(repo, sha)

      assert [%{name: "a.txt", type: :blob}, %{name: "nested", type: :tree}] = entries
      nested = Enum.find(entries, &(&1.name == "nested"))
      assert [%{name: "b.txt", type: :blob}] = GitStore.read_tree(repo, nested.ref)
    end

    test "skips symlinks", %{dir: dir, repo: repo} do
      path = Path.join(dir, "src")
      File.mkdir_p!(path)
      File.write!(Path.join(path, "a.txt"), "content")
      File.ln_s!("a.txt", Path.join(path, "link"))

      sha = GitStore.build_tree(repo, path)
      assert [%{name: "a.txt"}] = GitStore.read_tree(repo, sha)
    end

    test "skips ignored names at any depth", %{dir: dir, repo: repo} do
      path = Path.join(dir, "src")
      File.mkdir_p!(Path.join(path, "_build/keep_out"))
      File.mkdir_p!(Path.join(path, "nested/_build"))
      File.write!(Path.join(path, "a.txt"), "top\n")
      File.write!(Path.join(path, "_build/keep_out/junk.beam"), "x")
      File.write!(Path.join(path, "nested/_build/junk.beam"), "x")

      sha = GitStore.build_tree(repo, path, ignore: ["_build"])
      entries = GitStore.read_tree(repo, sha)

      assert [%{name: "a.txt"}, %{name: "nested"}] = entries
      nested = Enum.find(entries, &(&1.name == "nested"))
      assert GitStore.read_tree(repo, nested.ref) == []
    end

    test "always skips .git directories", %{dir: dir, repo: repo} do
      path = Path.join(dir, "src")
      File.mkdir_p!(Path.join(path, ".git/objects"))
      File.write!(Path.join(path, "a.txt"), "top\n")
      File.write!(Path.join(path, ".git/HEAD"), "ref: refs/heads/main\n")

      sha = GitStore.build_tree(repo, path)
      assert [%{name: "a.txt"}] = GitStore.read_tree(repo, sha)
    end
  end

  describe "commit" do
    test "write/read round-trip preserves tree, parents, author, and message", %{repo: repo} do
      tree = GitStore.write_tree(repo, [])
      author = %{name: "Ada", email: "ada@example.com"}

      sha = GitStore.write_commit(repo, tree, [], author, "initial")
      commit = GitStore.read_commit(repo, sha)

      assert commit.tree == tree
      assert commit.parent == []
      assert commit.message == "initial"
      assert commit.author.name == "Ada"
      assert commit.author.email == "ada@example.com"
      assert commit.hash == sha
    end

    test "stores multiple parents in order", %{repo: repo} do
      tree = GitStore.write_tree(repo, [])
      author = %{name: "a", email: "a@b"}

      root = GitStore.write_commit(repo, tree, [], author, "root")
      child = GitStore.write_commit(repo, tree, [root], author, "child")

      assert GitStore.read_commit(repo, child).parent == [root]
    end
  end

  describe "checkout/3" do
    test "materializes the tree at a commit into a directory", %{dir: dir, repo: repo} do
      path = Path.join(dir, "work")
      File.mkdir_p!(Path.join(path, "sub"))
      File.write!(Path.join(path, "top.txt"), "top content\n")
      File.write!(Path.join(path, "sub/inner.txt"), "inner content\n")

      tree = GitStore.build_tree(repo, path)
      sha = GitStore.write_commit(repo, tree, [], %{name: "a", email: "a@b"}, "snapshot")

      dest = Path.join(dir, "checkout")
      :ok = GitStore.checkout(repo, sha, dest)

      assert File.read!(Path.join(dest, "top.txt")) == "top content\n"
      assert File.read!(Path.join(dest, "sub/inner.txt")) == "inner content\n"
    end

    test "raises for a non-commit SHA", %{dir: dir, repo: repo} do
      assert_raise ArgumentError, fn ->
        GitStore.checkout(repo, String.duplicate("0", 40), Path.join(dir, "x"))
      end
    end

    test "rejects path-traversal tree entry names", %{dir: dir, repo: repo} do
      blob = GitStore.write_blob(repo, "evil")

      tree =
        GitStore.write_tree(repo, [
          %{name: "../escape", mode: "100644", type: :blob, ref: blob}
        ])

      sha = GitStore.write_commit(repo, tree, [], %{name: "a", email: "a@b"}, "x")

      assert_raise ArgumentError, fn ->
        GitStore.checkout(repo, sha, Path.join(dir, "dest"))
      end

      refute File.exists?(Path.join(dir, "escape"))
    end
  end

  test "full round-trip: build_tree -> commit -> checkout", %{dir: dir, repo: repo} do
    path = Path.join(dir, "project")
    File.mkdir_p!(path)
    File.write!(Path.join(path, "README.md"), "# Cadence\n")

    tree = GitStore.build_tree(repo, path)

    commit =
      GitStore.write_commit(repo, tree, [], %{name: "Ada", email: "ada@example.com"}, "init")

    dest = Path.join(dir, "restored")
    :ok = GitStore.checkout(repo, commit, dest)
    assert File.read!(Path.join(dest, "README.md")) == "# Cadence\n"
  end

  describe "diff_trees/3" do
    test "detects added, modified, deleted, and unchanged files", %{dir: dir, repo: repo} do
      old_tree =
        build_file_tree(repo, Path.join(dir, "old"), %{
          "a.txt" => "one\n",
          "b.txt" => "same\n",
          "del.txt" => "x\n"
        })

      new_tree =
        build_file_tree(repo, Path.join(dir, "new"), %{
          "a.txt" => "changed\n",
          "b.txt" => "same\n",
          "new.txt" => "y\n"
        })

      changes = GitStore.diff_trees(repo, old_tree, new_tree)

      assert %{path: "a.txt", status: :modified, new_content: "changed\n"} =
               Enum.find(changes, &(&1.path == "a.txt"))

      assert %{path: "new.txt", status: :added} = Enum.find(changes, &(&1.path == "new.txt"))

      assert %{path: "del.txt", status: :deleted, old_content: "x\n"} =
               Enum.find(changes, &(&1.path == "del.txt"))

      refute Enum.find(changes, &(&1.path == "b.txt"))
    end

    test "treats a nil old tree as a root commit (all added)", %{dir: dir, repo: repo} do
      new_tree = build_file_tree(repo, Path.join(dir, "new"), %{"a.txt" => "x\n"})
      assert [%{path: "a.txt", status: :added}] = GitStore.diff_trees(repo, nil, new_tree)
    end

    test "handles nested directories", %{dir: dir, repo: repo} do
      old_tree = build_file_tree(repo, Path.join(dir, "old"), %{"sub/a.txt" => "old\n"})

      new_tree =
        build_file_tree(repo, Path.join(dir, "new"), %{
          "sub/a.txt" => "new\n",
          "sub/b.txt" => "extra\n"
        })

      changes = GitStore.diff_trees(repo, old_tree, new_tree)
      paths = changes |> Enum.map(& &1.path) |> Enum.sort()

      assert paths == ["sub/a.txt", "sub/b.txt"]
      assert %{status: :modified} = Enum.find(changes, &(&1.path == "sub/a.txt"))
      assert %{status: :added} = Enum.find(changes, &(&1.path == "sub/b.txt"))
    end
  end

  defp build_file_tree(repo, dir, files) do
    Enum.each(files, fn {path, content} ->
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end)

    GitStore.build_tree(repo, dir)
  end
end
