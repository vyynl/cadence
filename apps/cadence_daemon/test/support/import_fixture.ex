defmodule Cadence.Daemon.ImportFixture do
  @moduledoc false
  # Builds small Git repositories for importer tests without shelling out.

  alias Cadence.Shared.GitStore

  @file_mode "100644"
  @ident "A U Thor <a@example.com>"

  @doc "Creates a bare repository with a symbolic main branch."
  def bare(root, name \\ "repo") do
    path = Path.join(root, name)
    git = GitStore.init(path, bare: true)
    File.write!(Path.join(git.home_dir, "HEAD"), "ref: refs/heads/main\n")
    git
  end

  @doc "Creates a worktree repository (`.git` directory) at `root/name`."
  def worktree(root, name \\ "work") do
    path = Path.join(root, name)
    File.mkdir_p!(path)
    git = GitStore.init(path, bare: false)
    File.write!(Path.join(git.home_dir, "HEAD"), "ref: refs/heads/main\n")
    git
  end

  @doc "The worktree path for a `worktree/2` repository."
  def work_dir(%GitStore{home_dir: home_dir}), do: Path.dirname(home_dir)

  @doc "Writes a commit whose tree contains `files` (a map of path => content)."
  def commit(git, files, parents, message, timestamp \\ 1_700_000_000) do
    tree = write_tree(git, files)
    ident = "#{@ident} #{timestamp} +0000"

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

    GitStore.write_raw(git, :commit, data)
  end

  @doc "Writes `files` into the worktree (creating directories as needed)."
  def write_worktree(%GitStore{home_dir: home_dir}, files) do
    dir = Path.dirname(home_dir)

    Enum.each(files, fn {name, content} ->
      path = Path.join(dir, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end)
  end

  @doc "Points a ref at `sha` (writes a loose ref)."
  def write_ref(git, ref, sha) do
    path = Path.join(git.home_dir, ref)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, sha <> "\n")
  end

  @doc "Writes `HEAD` to `target` (a symbolic ref or a detached SHA)."
  def write_head(git, target) do
    File.write!(Path.join(git.home_dir, "HEAD"), target <> "\n")
  end

  @doc "Writes a `shallow` file listing the boundary commits."
  def write_shallow(git, shas) do
    File.write!(Path.join(git.home_dir, "shallow"), Enum.join(shas, "\n") <> "\n")
  end

  @doc "Creates an annotated tag object pointing at `sha` and returns its SHA."
  def annotated_tag(git, sha, name) do
    GitStore.write_raw(
      git,
      :tag,
      "object #{sha}\ntype commit\ntag #{name}\ntagger #{@ident} 1700000000 +0000\n\nrelease\n"
    )
  end

  defp write_tree(git, files) do
    entries =
      Enum.map(files, fn {name, content} ->
        %{name: name, mode: @file_mode, type: :blob, ref: GitStore.write_blob(git, content)}
      end)

    GitStore.write_tree(git, entries)
  end
end
