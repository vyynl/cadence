defmodule Cadence.Shared.LLM.CommitMessageTest do
  use ExUnit.Case, async: true

  alias Cadence.Shared.LLM.CommitMessage

  describe "parse/1" do
    test "parses a well-formed response" do
      text = "SUMMARY: Add feature\nFLAG: in-progress\nDETAIL:\n- first thing\n- second thing\n"

      assert {:ok,
              %{
                summary: "Add feature",
                flag: :"in-progress",
                details: ["first thing", "second thing"]
              }} =
               CommitMessage.parse(text)
    end

    test "parses a response with no details" do
      assert {:ok, %{summary: "Just a summary", flag: :broken, details: []}} =
               CommitMessage.parse("SUMMARY: Just a summary\nFLAG: broken\n")
    end

    test "returns error when the summary is missing" do
      assert {:error, :missing_summary} = CommitMessage.parse("FLAG: broken\n")
      assert {:error, :missing_summary} = CommitMessage.parse("")
    end

    test "returns a nil flag for an unrecognized flag" do
      assert {:ok, %{flag: nil}} = CommitMessage.parse("SUMMARY: x\nFLAG: nonsense\n")
    end

    test "tolerates CRLF and blank lines" do
      text = "SUMMARY: Win\r\n\r\nFLAG: broken\r\nDETAIL:\r\n- a\r\n"
      assert {:ok, %{summary: "Win", flag: :broken, details: ["a"]}} = CommitMessage.parse(text)
    end
  end

  describe "clamp_flag/1" do
    test "never promotes to functioning" do
      assert CommitMessage.clamp_flag(:functioning) == :"in-progress"
    end

    test "passes through in-progress and broken" do
      assert CommitMessage.clamp_flag(:"in-progress") == :"in-progress"
      assert CommitMessage.clamp_flag(:broken) == :broken
    end

    test "defaults unknown or nil to in-progress" do
      assert CommitMessage.clamp_flag(nil) == :"in-progress"
      assert CommitMessage.clamp_flag(:weird) == :"in-progress"
    end
  end

  describe "render/1" do
    test "renders the summary alone when there are no details" do
      assert CommitMessage.render(%{summary: "s", details: []}) == "s"
    end

    test "renders the summary plus bullets" do
      assert CommitMessage.render(%{summary: "s", details: ["a", "b"]}) == "s\n\n- a\n- b"
    end
  end

  describe "build_prompt/1" do
    test "injects the diff into the template" do
      prompt = CommitMessage.build_prompt("DIFFTEXT")

      assert prompt =~ "DIFFTEXT"
      refute prompt =~ "{{diff}}"
      assert prompt =~ "SUMMARY:"
    end
  end

  describe "diff_to_text/2" do
    test "renders added, modified, and deleted paths with new contents" do
      changes = [
        %{path: "a.ex", status: :added, old_content: nil, new_content: "new"},
        %{path: "b.ex", status: :modified, old_content: "old", new_content: "newb"},
        %{path: "c.ex", status: :deleted, old_content: "gone", new_content: nil}
      ]

      text = CommitMessage.diff_to_text(changes)

      assert text =~ "A a.ex\nnew"
      assert text =~ "M b.ex\nnewb"
      assert text =~ "D c.ex"
      refute text =~ "gone"
    end

    test "truncates oversized contents" do
      changes = [%{path: "a.ex", status: :added, old_content: nil, new_content: "abcdefgh"}]

      text = CommitMessage.diff_to_text(changes, 4)

      assert text =~ "abcd"
      assert text =~ "truncated"
    end
  end
end
