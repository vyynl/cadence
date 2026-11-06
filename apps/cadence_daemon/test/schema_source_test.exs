defmodule Cadence.Daemon.Docs.SchemaSourceTest do
  use ExUnit.Case, async: false

  alias Cadence.Daemon.{ProjectLocation, Repo}
  alias Cadence.Daemon.Docs.SchemaSource
  alias Cadence.Shared.{Docs.Schema, Project}

  setup do
    root = Path.join(System.tmp_dir!(), "cadence_schema_#{System.unique_integer([:positive])}")
    work_dir = Path.join(root, "work")
    git_dir = Path.join(root, "git")
    File.mkdir_p!(work_dir)

    project =
      %{
        name: "p",
        slug: "schema-#{System.unique_integer([:positive])}",
        owner_id: Ecto.UUID.generate()
      }
      |> Project.changeset()
      |> Repo.insert!()

    %ProjectLocation{}
    |> ProjectLocation.changeset(%{
      project_id: project.id,
      work_dir: work_dir,
      git_dir: git_dir,
      created_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    on_exit(fn -> File.rm_rf!(root) end)

    %{work_dir: work_dir, project: project}
  end

  test "loads and parses the schema from the working tree", %{work_dir: work_dir} do
    File.write!(Path.join(work_dir, ".caddocs.yaml"), valid_schema())

    assert {:ok, %Schema{} = schema} = SchemaSource.load(work_dir)
    assert schema.index_file == "README.md"
    assert schema.docs_dir == "docs"
    assert [%{name: "Overview", required: true}] = schema.sections
  end

  test "reports a missing file", %{work_dir: work_dir} do
    assert SchemaSource.load(work_dir) == :no_schema
  end

  test "reports an invalid file without raising", %{work_dir: work_dir} do
    File.write!(Path.join(work_dir, ".caddocs.yaml"), "sections: []\n")
    assert SchemaSource.load(work_dir) == {:error, :missing_index_file}
  end

  test "refresh caches the parsed schema and clears it when removed", ctx do
    File.write!(Path.join(ctx.work_dir, ".caddocs.yaml"), valid_schema())

    assert {:ok, %Schema{}} = SchemaSource.refresh(ctx.project.id, ctx.work_dir)
    cached = Repo.get!(Project, ctx.project.id).docs_schema
    assert cached["index_file"] == "README.md"
    assert [%{"name" => "Overview"}] = cached["sections"]

    File.rm!(Path.join(ctx.work_dir, ".caddocs.yaml"))
    assert SchemaSource.refresh(ctx.project.id, ctx.work_dir) == :no_schema
    assert Repo.get!(Project, ctx.project.id).docs_schema == %{}
  end

  defp valid_schema do
    """
    index_file: README.md
    docs_dir: docs
    sections:
      - name: Overview
        required: true
        generated_from: "lib/**/*.ex"
    """
  end
end
