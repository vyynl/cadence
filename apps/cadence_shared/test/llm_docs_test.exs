defmodule Cadence.Shared.LLM.DocsTest do
  use ExUnit.Case, async: true

  alias Cadence.Shared.Docs.Schema
  alias Cadence.Shared.LLM.Docs

  @yaml """
  index_file: README.md
  docs_dir: docs/
  sections:
    - name: Overview
      required: true
    - name: API
      generated_from: "lib/**/*.ex"
  """

  setup do
    {:ok, schema} = Schema.parse(@yaml)
    %{schema: schema}
  end

  describe "prompt_version/0" do
    test "is the version embedded in result metadata" do
      assert Docs.prompt_version() == "docs-v1"
    end
  end

  describe "build_prompt/4" do
    test "substitutes the schema, current docs, and diff", %{schema: schema} do
      docs = %{"README.md" => "# Project\n## Overview\nold\n", "docs/api.md" => "## API\n"}
      diff = "M lib/cadence/foo.ex\n+def hello, do: :world"

      assert {:ok, prompt, _meta} = Docs.build_prompt(schema, docs, diff)

      assert prompt =~ "index_file"
      assert prompt =~ "=== README.md ==="
      assert prompt =~ "=== docs/api.md ==="
      assert prompt =~ "+def hello, do: :world"
      refute prompt =~ "{{schema}}"
      refute prompt =~ "{{docs}}"
      refute prompt =~ "{{diff}}"
    end

    test "renders the index file first", %{schema: schema} do
      docs = %{"README.md" => "# Project", "docs/api.md" => "## API"}
      assert {:ok, prompt, _meta} = Docs.build_prompt(schema, docs, "")

      {index_at, _} = :binary.match(prompt, "=== README.md ===")
      {api_at, _} = :binary.match(prompt, "=== docs/api.md ===")
      assert index_at < api_at
    end

    test "substituted content cannot inject further placeholders", %{schema: schema} do
      docs = %{"README.md" => "{{diff}} and {{schema}}"}
      assert {:ok, prompt, _meta} = Docs.build_prompt(schema, docs, "DIFF")

      assert prompt =~ "{{diff}} and {{schema}}"
      assert prompt =~ "DIFF"
    end

    test "binary non-index docs are marked, never inlined", %{schema: schema} do
      docs = %{"README.md" => "# Project", "docs/bin.md" => <<0, 1, 2>>}
      assert {:ok, prompt, _meta} = Docs.build_prompt(schema, docs, "")

      assert prompt =~ "(binary content omitted)"
      refute prompt =~ <<0, 1, 2>>
    end

    test "a binary index file is a hard context error", %{schema: schema} do
      docs = %{"README.md" => <<0, 1, 2>>}
      assert Docs.build_prompt(schema, docs, "") == {:error, :context_too_large}
    end

    test "fails when even the schema cannot fit", %{schema: schema} do
      docs = %{"README.md" => "# Project"}

      assert Docs.build_prompt(schema, docs, "", max_context_bytes: 10) ==
               {:error, :context_too_large}
    end

    test "max_doc_bytes caps the docs portion independently", %{schema: schema} do
      docs = %{"README.md" => "# Project"}

      assert Docs.build_prompt(schema, docs, "", max_doc_bytes: 5) ==
               {:error, :context_too_large}
    end

    test "fails when the index file cannot fit", %{schema: schema} do
      schema_size =
        schema |> Schema.to_map() |> Jason.encode!(pretty: true) |> byte_size()

      docs = %{"README.md" => String.duplicate("#", 200)}

      assert Docs.build_prompt(schema, docs, "", max_context_bytes: schema_size + 20) ==
               {:error, :context_too_large}
    end

    test "omits non-index docs that do not fit and marks them read-only", %{schema: schema} do
      schema_size =
        schema |> Schema.to_map() |> Jason.encode!(pretty: true) |> byte_size()

      index_block = byte_size("=== README.md ===\n# Project")
      budget = schema_size + index_block + 5

      docs = %{"README.md" => "# Project", "docs/big.md" => String.duplicate("x", 500)}

      assert {:ok, prompt, meta} =
               Docs.build_prompt(schema, docs, "", max_context_bytes: budget)

      assert prompt =~ "Read-only documentation files"
      assert meta.read_only_paths == ["docs/big.md"]
      assert meta.writable_paths == ["README.md"]
      refute prompt =~ String.duplicate("x", 20)
    end

    test "marks a binary diff as omitted", %{schema: schema} do
      docs = %{"README.md" => "# Project"}

      assert {:ok, prompt, _meta} = Docs.build_prompt(schema, docs, <<0, 1, 2>>)
      assert prompt =~ "(binary diff omitted)"
      refute prompt =~ <<0, 1, 2>>
    end

    test "truncates a large diff with a marker and safe UTF-8", %{schema: schema} do
      docs = %{"README.md" => "# Project"}
      diff = String.duplicate("é", 100)

      assert {:ok, prompt, _meta} = Docs.build_prompt(schema, docs, diff, max_diff_bytes: 20)
      assert prompt =~ "... (truncated)"
      assert String.valid?(prompt)
    end
  end

  describe "parse/3" do
    @response """
    DOCS_BEGIN
    FILE MODIFY README.md
    <<<
    # Project

    ## Overview
    updated
    >>>
    FILE CREATE docs/api.md
    <<<
    ## API
    >>>
    DOCS_END
    """

    test "parses MODIFY and CREATE operations", %{schema: schema} do
      assert {:ok, ops} = Docs.parse(@response, schema)

      assert ops == [
               {:modify, "README.md", "# Project\n\n## Overview\nupdated"},
               {:create, "docs/api.md", "## API"}
             ]
    end

    test "handles CRLF", %{schema: schema} do
      assert {:ok, ops} = Docs.parse(String.replace(@response, "\n", "\r\n"), schema)
      assert length(ops) == 2
    end

    test "accepts an exact allowed-path list" do
      assert {:ok, ops} = Docs.parse(@response, ["README.md", "docs/api.md"])
      assert length(ops) == 2

      assert Docs.parse(@response, ["README.md"]) == {:error, :unknown_path}
    end

    test "returns an empty op list for an empty block", %{schema: schema} do
      assert Docs.parse("DOCS_BEGIN\nDOCS_END", schema) == {:ok, []}
    end

    test "rejects unknown paths", %{schema: schema} do
      text = "DOCS_BEGIN\nFILE MODIFY lib/foo.ex\n<<<\nx\n>>>\nDOCS_END"
      assert Docs.parse(text, schema) == {:error, :unknown_path}
    end

    test "rejects traversal paths", %{schema: schema} do
      text = "DOCS_BEGIN\nFILE MODIFY docs/../README.md\n<<<\nx\n>>>\nDOCS_END"
      assert Docs.parse(text, schema) == {:error, :unknown_path}
    end

    test "rejects duplicate paths", %{schema: schema} do
      text = """
      DOCS_BEGIN
      FILE MODIFY README.md
      <<<
      one
      >>>
      FILE MODIFY README.md
      <<<
      two
      >>>
      DOCS_END
      """

      assert Docs.parse(text, schema) == {:error, :duplicate_path}
    end

    test "rejects DELETE and unknown operations", %{schema: schema} do
      text = "DOCS_BEGIN\nFILE DELETE README.md\n<<<\nx\n>>>\nDOCS_END"
      assert Docs.parse(text, schema) == {:error, :invalid_operation}
    end

    test "rejects missing markers", %{schema: schema} do
      assert Docs.parse("FILE MODIFY README.md\n<<<\nx\n>>>", schema) == {:error, :missing_begin}

      assert Docs.parse("DOCS_BEGIN\nFILE MODIFY README.md\n<<<\nx\n>>>", schema) ==
               {:error, :missing_end}
    end

    test "rejects malformed headers", %{schema: schema} do
      assert Docs.parse("DOCS_BEGIN\nFILE MODIFY\n<<<\nx\n>>>\nDOCS_END", schema) ==
               {:error, :malformed_op}

      assert Docs.parse("DOCS_BEGIN\nwat\n<<<\nx\n>>>\nDOCS_END", schema) ==
               {:error, :malformed_op}
    end

    test "rejects missing content", %{schema: schema} do
      assert Docs.parse("DOCS_BEGIN\nFILE MODIFY README.md\nDOCS_END", schema) ==
               {:error, :missing_content}
    end

    test "enforces the op and file-size caps", %{schema: schema} do
      assert Docs.parse(@response, schema, max_ops: 1) == {:error, :too_many_ops}
      assert Docs.parse(@response, schema, max_file_bytes: 2) == {:error, :file_too_large}
    end

    test "rejects non-binary input", %{schema: schema} do
      assert Docs.parse(nil, schema) == {:error, :malformed_op}
    end

    test "rejects writes to read-only paths", %{schema: schema} do
      text = "DOCS_BEGIN\nFILE MODIFY docs/big.md\n<<<\noverwrite\n>>>\nDOCS_END"

      assert Docs.parse(text, schema, read_only_paths: ["docs/big.md"]) ==
               {:error, :read_only_path}
    end
  end

  describe "validate_required/2" do
    test "accepts a required section heading at any level", %{schema: schema} do
      assert Docs.validate_required(schema, %{"README.md" => "# Project\n## Overview\nx"}) == :ok
      assert Docs.validate_required(schema, %{"README.md" => "# Project\n### Overview\nx"}) == :ok
    end

    test "reports missing required sections", %{schema: schema} do
      assert Docs.validate_required(schema, %{"README.md" => "# Project"}) ==
               {:error, {:missing_sections, ["Overview"]}}

      assert Docs.validate_required(schema, %{}) ==
               {:error, {:missing_sections, ["Overview"]}}
    end
  end

  describe "apply_ops/2" do
    test "overlays create and modify operations" do
      files = %{"README.md" => "old", "docs/keep.md" => "keep"}

      assert {:ok, files} =
               Docs.apply_ops(files, [
                 {:modify, "README.md", "new"},
                 {:create, "docs/api.md", "api"}
               ])

      assert files == %{"README.md" => "new", "docs/keep.md" => "keep", "docs/api.md" => "api"}
    end

    test "rejects malformed operations" do
      assert Docs.apply_ops(%{}, [{:delete, "README.md", "x"}]) == {:error, :malformed_op}
    end

    test "rejects CREATE for an existing path and MODIFY for a missing path" do
      files = %{"README.md" => "old"}

      assert Docs.apply_ops(files, [{:create, "README.md", "new"}]) ==
               {:error, :already_exists}

      assert Docs.apply_ops(files, [{:modify, "docs/missing.md", "new"}]) ==
               {:error, :not_found}
    end
  end
end
