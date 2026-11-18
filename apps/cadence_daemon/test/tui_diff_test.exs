defmodule Cadence.Daemon.TUI.DiffTest do
  use ExUnit.Case, async: true

  alias Cadence.Daemon.TUI.Diff

  test "formats files, lines, and truncation into display rows" do
    payload = %{
      "truncated" => true,
      "files" => [
        %{
          "path" => "lib/a.ex",
          "status" => "modified",
          "binary" => false,
          "truncated" => true,
          "lines" => [
            %{"kind" => "ctx", "text" => "defmodule A do"},
            %{"kind" => "del", "text" => "  old"},
            %{"kind" => "add", "text" => "  new"},
            %{"kind" => "skip", "text" => "…"}
          ]
        }
      ]
    }

    assert Diff.format(payload) == [
             %{kind: :file, text: "lib/a.ex  (modified)"},
             %{kind: :ctx, text: "  defmodule A do"},
             %{kind: :del, text: "-   old"},
             %{kind: :add, text: "+   new"},
             %{kind: :skip, text: "  …"},
             %{kind: :note, text: "  … (truncated)"},
             %{kind: :note, text: "… more files omitted"}
           ]
  end

  test "binary files get a note instead of lines" do
    payload = %{"files" => [%{"path" => "logo.png", "status" => "added", "binary" => true}]}

    assert Diff.format(payload) == [
             %{kind: :file, text: "logo.png  (added)"},
             %{kind: :note, text: "  (binary file)"}
           ]
  end

  test "an empty payload renders the empty note" do
    assert Diff.format(%{"files" => []}) == [%{kind: :note, text: "(no changes)"}]
    assert Diff.format(nil) == [%{kind: :note, text: "(no changes)"}]
    assert Diff.format(%{}) == [%{kind: :note, text: "(no changes)"}]
  end

  test "docs callers can override the empty text" do
    assert Diff.format(%{"files" => []}, empty: "(no docs changes)") == [
             %{kind: :note, text: "(no docs changes)"}
           ]
  end

  test "an error tuple becomes a note, so a 409 renders in the pane" do
    assert Diff.format({:error, %{message: "no docs commit for this node"}}) == [
             %{kind: :note, text: "no docs commit for this node"}
           ]

    assert Diff.format({:error, "boom"}) == [%{kind: :note, text: "boom"}]
  end

  test "unknown line kinds degrade to context rows" do
    payload = %{
      "files" => [
        %{"path" => "a", "status" => "b", "lines" => [%{"kind" => "??", "text" => "x"}]}
      ]
    }

    assert Diff.format(payload) == [
             %{kind: :file, text: "a  (b)"},
             %{kind: :ctx, text: "  x"}
           ]
  end

  test "missing fields fall back instead of crashing" do
    payload = %{"files" => [%{"lines" => [%{}]}]}

    assert Diff.format(payload) == [
             %{kind: :file, text: "?  (?)"},
             %{kind: :ctx, text: "  "}
           ]
  end
end
