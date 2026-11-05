defmodule Cadence.Shared.LLM.MeldTest do
  use ExUnit.Case, async: false

  alias Cadence.Shared.LLM
  alias Cadence.Shared.LLM.Meld, as: MeldLLM

  @parents [
    %{
      id: "p1",
      message: "first session",
      flags: [:"in-progress"],
      files: %{"a.txt" => %{ref: "r1", content: "one"}, "shared.txt" => %{ref: "s", content: "s"}}
    },
    %{
      id: "p2",
      message: "second session",
      flags: [:broken],
      files: %{"a.txt" => %{ref: "r2", content: "two"}, "shared.txt" => %{ref: "s", content: "s"}}
    }
  ]

  @conflicts %{
    "a.txt" => [
      %{id: "p1", ref: "r1", content: "one"},
      %{id: "p2", ref: "r2", content: "two"}
    ]
  }

  describe "prompt_version/0" do
    test "is the version embedded in result metadata" do
      assert MeldLLM.prompt_version() == "meld-v1"
    end
  end

  describe "build_prompt/3" do
    test "substitutes the parent count, summaries, and conflicts" do
      assert {:ok, prompt} = MeldLLM.build_prompt(@parents, @conflicts)

      assert prompt =~ "between 2 session snapshots"
      assert prompt =~ "Parent 1 (id: p1)"
      assert prompt =~ "Message: first session"
      assert prompt =~ "Flags: in-progress"
      assert prompt =~ "Flags: broken"
      assert prompt =~ "a.txt"
      assert prompt =~ "File: a.txt"
      assert prompt =~ "--- parent p1 ---"
      assert prompt =~ "--- parent p2 ---"

      refute prompt =~ "{{parent_count}}"
      refute prompt =~ "{{parents}}"
      refute prompt =~ "{{conflicts}}"
    end

    test "file content cannot inject further placeholders" do
      parents = [
        %{id: "p1", message: "{{conflicts}}", flags: [], files: %{"{{parents}}" => file("x")}},
        %{id: "p2", message: "m", flags: [], files: %{"b" => file("y")}}
      ]

      assert {:ok, prompt} = MeldLLM.build_prompt(parents, %{})

      assert prompt =~ "Message: {{conflicts}}"
      assert prompt =~ "{{parents}}"
    end

    test "truncates conflict content within the context budget" do
      conflicts = %{
        "a.txt" => [
          %{id: "p1", ref: "r1", content: String.duplicate("x", 500)},
          %{id: "p2", ref: "r2", content: String.duplicate("y", 500)}
        ]
      }

      assert {:ok, prompt} = MeldLLM.build_prompt(@parents, conflicts, max_context_bytes: 80)

      assert prompt =~ "... (truncated)"
      assert not String.contains?(prompt, String.duplicate("x", 500))
    end

    test "a budget that cannot fit every conflict path is an error" do
      conflicts =
        Map.new(1..20, fn index ->
          path = "file_#{String.pad_leading(Integer.to_string(index), 2, "0")}.txt"
          {path, [%{id: "p1", ref: "r", content: "content"}]}
        end)

      assert MeldLLM.build_prompt(@parents, conflicts, max_context_bytes: 40) ==
               {:error, :context_too_large}
    end

    test "a one-byte content budget cannot crash on a multibyte boundary" do
      conflicts = %{"a.txt" => [%{id: "p1", ref: "r", content: "é-rest-of-file"}]}

      assert {:ok, prompt} = MeldLLM.build_prompt(@parents, conflicts, max_context_bytes: 13)
      assert prompt =~ "... (truncated)"
    end

    test "never sends binary conflict content to the model" do
      conflicts = %{"blob.bin" => [%{id: "p1", ref: "r", content: <<0, 1, 2>>}]}

      assert {:ok, prompt} = MeldLLM.build_prompt(@parents, conflicts)

      assert prompt =~ "(binary content omitted)"
    end

    test "caps long parent file lists" do
      files = Map.new(1..200, fn index -> {"dir/file_#{index}.txt", file("x")} end)

      parents = [
        %{id: "p1", message: "m", flags: [], files: files},
        %{id: "p2", message: "m", flags: [], files: %{}}
      ]

      assert {:ok, prompt} = MeldLLM.build_prompt(parents, %{}, max_context_bytes: 60)

      assert prompt =~ "more files"
    end
  end

  describe "parse/3 happy path" do
    test "reads create, modify, and delete operations with full content" do
      text = """
      MELD_BEGIN
      FILE MODIFY src/app.ex
      <<<
      defmodule App do
      end
      >>>
      FILE CREATE lib/new.txt
      <<<
      hello
      >>>
      FILE DELETE old/path.txt
      MELD_END
      """

      allowed = ["src/app.ex", "lib/new.txt", "old/path.txt"]

      assert MeldLLM.parse(text, allowed) ==
               {:ok,
                [
                  {:modify, "src/app.ex", "defmodule App do\nend"},
                  {:create, "lib/new.txt", "hello"},
                  {:delete, "old/path.txt"}
                ]}
    end

    test "a blank line before the terminator keeps a trailing newline" do
      text = """
      MELD_BEGIN
      FILE MODIFY a.txt
      <<<
      line one
      line two

      >>>
      MELD_END
      """

      assert MeldLLM.parse(text, ["a.txt"]) ==
               {:ok, [{:modify, "a.txt", "line one\nline two\n"}]}
    end

    test "an empty file and an empty body are valid" do
      text = """
      MELD_BEGIN
      FILE CREATE empty.txt
      <<<
      >>>
      MELD_END
      """

      assert MeldLLM.parse(text, ["empty.txt"]) == {:ok, [{:create, "empty.txt", ""}]}
      assert MeldLLM.parse("MELD_BEGIN\nMELD_END", []) == {:ok, []}
    end

    test "paths may contain spaces" do
      text = "MELD_BEGIN\nFILE DELETE src/my file.txt\nMELD_END\n"

      assert MeldLLM.parse(text, ["src/my file.txt"]) ==
               {:ok, [{:delete, "src/my file.txt"}]}
    end
  end

  describe "parse/3 errors" do
    test "missing delimiters" do
      assert MeldLLM.parse("just text", []) == {:error, :missing_begin}

      assert MeldLLM.parse("MELD_BEGIN\nFILE DELETE a.txt\n", ["a.txt"]) ==
               {:error, :missing_end}
    end

    test "malformed and invalid operations" do
      assert MeldLLM.parse("MELD_BEGIN\nHELLO\nMELD_END", []) == {:error, :malformed_op}
      assert MeldLLM.parse("MELD_BEGIN\nFILE DELETE\nMELD_END", []) == {:error, :malformed_op}

      assert MeldLLM.parse("MELD_BEGIN\nFILE RENAME a.txt\nMELD_END", ["a.txt"]) ==
               {:error, :invalid_operation}
    end

    test "unknown and duplicate paths" do
      assert MeldLLM.parse("MELD_BEGIN\nFILE DELETE b.txt\nMELD_END", ["a.txt"]) ==
               {:error, :unknown_path}

      text = "MELD_BEGIN\nFILE DELETE a.txt\nFILE DELETE a.txt\nMELD_END\n"
      assert MeldLLM.parse(text, ["a.txt"]) == {:error, :duplicate_path}
    end

    test "missing content block" do
      assert MeldLLM.parse("MELD_BEGIN\nFILE MODIFY a.txt\nMELD_END", ["a.txt"]) ==
               {:error, :missing_content}

      assert MeldLLM.parse("MELD_BEGIN\nFILE MODIFY a.txt\n<<<\nunterminated\nMELD_END", [
               "a.txt"
             ]) ==
               {:error, :missing_content}
    end

    test "caps" do
      two_ops = "MELD_BEGIN\nFILE DELETE a.txt\nFILE DELETE b.txt\nMELD_END\n"

      assert MeldLLM.parse(two_ops, ["a.txt", "b.txt"], max_ops: 1) ==
               {:error, :too_many_ops}

      large =
        "MELD_BEGIN\nFILE MODIFY a.txt\n<<<\n" <> String.duplicate("x", 10) <> "\n>>>\nMELD_END"

      assert MeldLLM.parse(large, ["a.txt"], max_file_bytes: 5) == {:error, :file_too_large}
    end

    test "never returns a path outside the allowlist" do
      text = "MELD_BEGIN\nFILE DELETE ../escape\nFILE DELETE /etc/passwd\nMELD_END\n"

      assert MeldLLM.parse(text, ["safe.txt"]) == {:error, :unknown_path}
    end
  end

  test "provider/0 reflects the configured provider" do
    previous = Application.get_env(:cadence_shared, LLM)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:cadence_shared, LLM, previous),
        else: Application.delete_env(:cadence_shared, LLM)
    end)

    Application.put_env(:cadence_shared, LLM, provider: "openai", model: "gpt-test")

    assert LLM.provider() == "openai"
  end

  defp file(content) do
    %{ref: :crypto.hash(:sha, content) |> Base.encode16(case: :lower), content: content}
  end
end
