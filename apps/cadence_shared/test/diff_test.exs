defmodule Cadence.Shared.DiffTest do
  use ExUnit.Case, async: true

  alias Cadence.Shared.Diff

  test "modified file produces ctx/add/del lines" do
    change = %{
      path: "a.txt",
      status: :modified,
      old_content: "a\nb\nc\n",
      new_content: "a\nx\nc\n"
    }

    %{files: [file], truncated: false} = Diff.files([change])

    assert file.path == "a.txt"
    assert file.status == :modified
    refute file.binary
    assert kinds(file) == [:ctx, :del, :add, :ctx]
    assert texts(file) == ["a", "b", "x", "c"]
  end

  test "added and deleted files are wholly one kind" do
    added = %{path: "new.txt", status: :added, old_content: nil, new_content: "one\ntwo\n"}
    deleted = %{path: "old.txt", status: :deleted, old_content: "gone\n", new_content: nil}

    %{files: [a, d]} = Diff.files([added, deleted])

    assert kinds(a) == [:add, :add]
    assert kinds(d) == [:del]
  end

  test "identical content yields no lines" do
    change = %{path: "same", status: :modified, old_content: "a\nb\n", new_content: "a\nb\n"}
    %{files: [file]} = Diff.files([change])
    assert file.lines == []
  end

  test "collapses long unchanged runs into a skip marker" do
    old = Enum.map_join(1..20, "\n", &"line#{&1}") <> "\n"
    new = String.replace(old, "line10", "CHANGED")

    change = %{path: "big", status: :modified, old_content: old, new_content: new}
    %{files: [file]} = Diff.files([change], context: 1)

    assert Enum.any?(file.lines, &(&1.kind == :skip))
    assert Enum.any?(file.lines, &(&1.kind == :del and &1.text == "line10"))
    assert Enum.any?(file.lines, &(&1.kind == :add and &1.text == "CHANGED"))
    assert length(file.lines) < 20
  end

  test "caps lines per file and files overall" do
    big = %{
      path: "big",
      status: :added,
      old_content: nil,
      new_content: Enum.map_join(1..10, "\n", &"l#{&1}")
    }

    %{files: [file]} = Diff.files([big], max_lines_per_file: 3)
    assert length(file.lines) == 3
    assert file.truncated

    files =
      for i <- 1..5, do: %{path: "f#{i}", status: :added, old_content: nil, new_content: "x"}

    %{files: kept, truncated: true} = Diff.files(files, max_files: 2)
    assert length(kept) == 2
  end

  test "flags binary content and skips line diffing" do
    change = %{path: "bin", status: :added, old_content: nil, new_content: <<1, 0, 2>>}
    %{files: [file]} = Diff.files([change])
    assert file.binary
    assert file.lines == []
  end

  defp kinds(file), do: Enum.map(file.lines, & &1.kind)
  defp texts(file), do: Enum.map(file.lines, & &1.text)
end
