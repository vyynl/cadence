defmodule Cadence.Server.Actions.StagingTest do
  use ExUnit.Case, async: true

  alias Cadence.Server.Actions.{Artifacts, Staging}
  alias Cadence.Server.ProjectGit
  alias Cadence.Shared.GitStore

  setup do
    repo = ProjectGit.init(Ecto.UUID.generate())

    commit =
      write_commit(repo, %{
        "Dockerfile" => "FROM alpine:3.20\n",
        "actions/manifest.json" => ~s({"actions":[]}\n),
        "src/app.ex" => "defmodule App do\nend\n"
      })

    base = Path.join(System.tmp_dir!(), "cadence_staging_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)

    %{repo: repo, commit: commit, base: base}
  end

  describe "stage/4" do
    test "walk/3 does not materialize the snapshot", %{repo: repo, commit: commit, base: base} do
      dest = Path.join(base, "code")

      assert {:ok, _blobs} =
               Staging.walk(repo, commit, %{max_files: 100, max_bytes: 1_000_000})

      refute File.exists?(dest)
    end

    test "writes every blob under the destination", %{repo: repo, commit: commit, base: base} do
      dest = Path.join(base, "code")

      assert {:ok, blobs} =
               Staging.stage(repo, commit, dest, %{max_files: 100, max_bytes: 1_000_000})

      assert Enum.map(blobs, & &1.path) == [
               "Dockerfile",
               "actions/manifest.json",
               "src/app.ex"
             ]

      assert File.read!(Path.join(dest, "src/app.ex")) == "defmodule App do\nend\n"
    end

    test "replaces stale destination content", %{repo: repo, commit: commit, base: base} do
      dest = Path.join(base, "code")
      File.mkdir_p!(dest)
      File.write!(Path.join(dest, "from-previous-run.txt"), "stale")

      assert {:ok, _blobs} =
               Staging.stage(repo, commit, dest, %{max_files: 100, max_bytes: 1_000_000})

      refute File.exists?(Path.join(dest, "from-previous-run.txt"))
    end

    test "refuses a snapshot over the file cap", %{repo: repo, commit: commit, base: base} do
      assert Staging.stage(repo, commit, Path.join(base, "code"), %{
               max_files: 1,
               max_bytes: 1_000_000
             }) == {:error, :too_many_files}
    end

    test "refuses a snapshot over the byte cap", %{repo: repo, commit: commit, base: base} do
      assert Staging.stage(repo, commit, Path.join(base, "code"), %{
               max_files: 100,
               max_bytes: 1
             }) == {:error, :too_many_bytes}
    end

    test "a commit missing from the store is an error", %{repo: repo, base: base} do
      assert Staging.stage(repo, String.duplicate("0", 40), Path.join(base, "code"), %{
               max_files: 100,
               max_bytes: 1_000_000
             }) == {:error, :missing_object}
    end
  end

  describe "build_context/2" do
    test "archives relative names without leaking the host path", %{
      repo: repo,
      commit: commit,
      base: base
    } do
      dest = Path.join(base, "code")
      {:ok, blobs} = Staging.stage(repo, commit, dest, %{max_files: 100, max_bytes: 1_000_000})

      assert {:ok, tar} = Staging.build_context(dest, Enum.map(blobs, & &1.path))
      tar_path = Path.join(base, "context.tar")
      File.write!(tar_path, tar)

      assert {:ok, names} = :erl_tar.table(String.to_charlist(tar_path), [:compressed])
      names = Enum.map(names, &to_string/1)
      assert Enum.sort(names) == ["Dockerfile", "actions/manifest.json", "src/app.ex"]
    end

    test "filters unsafe archive names", %{base: base} do
      code_dir = Path.join(base, "code")
      File.mkdir_p!(code_dir)
      File.write!(Path.join(code_dir, "ok.txt"), "ok")

      assert {:ok, tar} =
               Staging.build_context(code_dir, ["../escape.txt", "/abs.txt", "ok.txt"])

      tar_path = Path.join(base, "context.tar")
      File.write!(tar_path, tar)

      assert {:ok, names} = :erl_tar.table(String.to_charlist(tar_path), [:compressed])
      assert Enum.map(names, &to_string/1) == ["ok.txt"]
    end

    test "a missing directory is a shape-only error", %{base: base} do
      assert Staging.build_context(Path.join(base, "nope"), ["x"]) ==
               {:error, :build_context_failed}
    end
  end

  describe "artifacts" do
    test "a run with no output collects nothing", %{base: base} do
      assert Artifacts.collect(Path.join(base, "missing"), Path.join(base, "artifacts"), 1_000) ==
               {:ok, []}
    end

    test "copies nested regular files and lists them", %{base: base} do
      source = Path.join(base, "out")
      File.mkdir_p!(Path.join(source, "nested"))
      File.write!(Path.join(source, "report.txt"), "ok\n")
      File.write!(Path.join([source, "nested", "data.csv"]), "a,b\n")

      dest = Path.join(base, "artifacts")

      assert {:ok, files} = Artifacts.collect(source, dest, 1_000)
      assert files == ["nested/data.csv", "report.txt"]
      assert File.read!(Path.join(dest, "report.txt")) == "ok\n"

      assert Artifacts.list(dest) == [
               %{path: "nested/data.csv", size: 4},
               %{path: "report.txt", size: 3}
             ]
    end

    test "skips symlinks so a run cannot pull host files", %{base: base} do
      source = Path.join(base, "out")
      File.mkdir_p!(source)
      File.write!(Path.join(source, "real.txt"), "real")
      File.ln_s!(Path.join(source, "real.txt"), Path.join(source, "link.txt"))
      File.ln_s!("/etc/passwd", Path.join(source, "passwd"))

      dest = Path.join(base, "artifacts")

      assert {:ok, files} = Artifacts.collect(source, dest, 1_000)
      assert files == ["real.txt"]
      refute File.exists?(Path.join(dest, "link.txt"))
    end

    test "refuses an output tree over the byte cap", %{base: base} do
      source = Path.join(base, "out")
      File.mkdir_p!(source)
      File.write!(Path.join(source, "big.bin"), "three")

      assert Artifacts.collect(source, Path.join(base, "artifacts"), 1) == {:error, :too_large}
    end

    test "refuses an output tree over the file cap", %{base: base} do
      source = Path.join(base, "out")
      File.mkdir_p!(source)

      for index <- 1..(Artifacts.max_files() + 1) do
        File.write!(Path.join(source, "file-#{index}.txt"), "")
      end

      assert Artifacts.collect(source, Path.join(base, "artifacts"), 1_000_000) ==
               {:error, :too_many_files}
    end
  end

  defp write_commit(repo, files) do
    {:ok, tree} = GitStore.put_files(repo, files)

    GitStore.write_commit(repo, tree, [], %{name: "test", email: "test@example.com"}, "snapshot")
  end
end
