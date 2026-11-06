defmodule Cadence.Shared.Docs.SchemaTest do
  use ExUnit.Case, async: true

  alias Cadence.Shared.Docs.Schema
  alias Cadence.Shared.Docs.Schema.Section

  @valid """
  index_file: README.md
  docs_dir: docs/
  sections:
    - name: Overview
      required: true
      max_words: 200
    - name: Architecture
      required: false
    - name: API
      generated_from: "lib/**/*.ex"
    - name: Changelog
      auto_append: true
  """

  describe "parse/1" do
    test "parses the spec §9.1 example" do
      assert {:ok, schema} = Schema.parse(@valid)

      assert schema.index_file == "README.md"
      assert schema.docs_dir == "docs"

      assert [
               %Section{name: "Overview", required: true, max_words: 200},
               %Section{name: "Architecture", required: false},
               %Section{name: "API", generated_from: "lib/**/*.ex"},
               %Section{name: "Changelog", auto_append: true}
             ] = schema.sections
    end

    test "defaults docs_dir to docs" do
      yaml = """
      index_file: README.md
      sections:
        - name: Overview
      """

      assert {:ok, %Schema{docs_dir: "docs"}} = Schema.parse(yaml)
    end

    test "normalizes a trailing slash on docs_dir" do
      yaml = """
      index_file: README.md
      docs_dir: documentation//
      sections:
        - name: Overview
      """

      assert {:ok, %Schema{docs_dir: "documentation"}} = Schema.parse(yaml)
    end

    test "ignores unknown top-level and section keys" do
      yaml = """
      index_file: README.md
      future_key: true
      sections:
        - name: Overview
          color: blue
      """

      assert {:ok, %Schema{sections: [%Section{name: "Overview"}]}} = Schema.parse(yaml)
    end

    test "rejects invalid YAML" do
      assert Schema.parse("[") == {:error, :invalid_yaml}
      assert Schema.parse("") == {:error, :missing_index_file}
      assert Schema.parse("- just\n- a list") == {:error, :invalid_yaml}
    end

    test "requires an index file" do
      yaml = """
      sections:
        - name: Overview
      """

      assert Schema.parse(yaml) == {:error, :missing_index_file}
    end

    test "rejects an unsafe index file" do
      assert parse_with_index("../README.md") == {:error, :invalid_index_file}
      assert parse_with_index("/README.md") == {:error, :invalid_index_file}
      assert parse_with_index("docs/../../README.md") == {:error, :invalid_index_file}
      assert parse_with_index("docs/") == {:error, :invalid_index_file}
    end

    test "rejects control characters in the index file" do
      assert Schema.parse("""
             index_file: "docs/a\\0b.md"
             sections:
               - name: Overview
             """) == {:error, :invalid_index_file}

      assert Schema.parse("""
             index_file: "docs/a\\nb.md"
             sections:
               - name: Overview
             """) == {:error, :invalid_index_file}
    end

    test "rejects an unsafe docs_dir" do
      assert parse_with_docs_dir("/docs") == {:error, :invalid_docs_dir}
      assert parse_with_docs_dir("../docs") == {:error, :invalid_docs_dir}
      assert parse_with_docs_dir("docs/../secrets") == {:error, :invalid_docs_dir}
      assert parse_with_docs_dir("") == {:error, :invalid_docs_dir}
      assert parse_with_docs_dir(123) == {:error, :invalid_docs_dir}
    end

    test "requires at least one section" do
      yaml = """
      index_file: README.md
      sections: []
      """

      assert Schema.parse(yaml) == {:error, :missing_sections}
    end

    test "rejects malformed sections" do
      yaml = """
      index_file: README.md
      sections:
        - just a string
      """

      assert Schema.parse(yaml) == {:error, :invalid_section}
    end

    test "requires a non-empty section name" do
      yaml = """
      index_file: README.md
      sections:
        - name: ""
      """

      assert Schema.parse(yaml) == {:error, :invalid_section_name}
    end

    test "rejects control characters in a section name" do
      yaml = """
      index_file: README.md
      sections:
        - name: "Overview\\nArchitecture"
      """

      assert Schema.parse(yaml) == {:error, :invalid_section_name}
    end

    test "rejects duplicate section names" do
      yaml = """
      index_file: README.md
      sections:
        - name: Overview
        - name: Overview
      """

      assert Schema.parse(yaml) == {:error, :duplicate_section}
    end

    test "rejects an invalid max_words" do
      for value <- ["0", "-1", "\"200\"", "true"] do
        yaml = """
        index_file: README.md
        sections:
          - name: Overview
            max_words: #{value}
        """

        assert Schema.parse(yaml) == {:error, :invalid_max_words}
      end
    end

    test "rejects an invalid generated_from" do
      yaml = """
      index_file: README.md
      sections:
        - name: API
          generated_from: ["lib/**/*.ex"]
      """

      assert Schema.parse(yaml) == {:error, :invalid_generated_from}
    end

    test "rejects non-boolean required/auto_append" do
      yaml = """
      index_file: README.md
      sections:
        - name: Overview
          required: "yes"
      """

      assert Schema.parse(yaml) == {:error, :invalid_required}

      yaml = """
      index_file: README.md
      sections:
        - name: Changelog
          auto_append: "yes"
      """

      assert Schema.parse(yaml) == {:error, :invalid_auto_append}
    end
  end

  describe "allowed_path?/2" do
    setup do
      {:ok, schema} = Schema.parse(@valid)
      %{schema: schema}
    end

    test "allows the index file and files under docs_dir", %{schema: schema} do
      assert Schema.allowed_path?(schema, "README.md")
      assert Schema.allowed_path?(schema, "docs/guide.md")
      assert Schema.allowed_path?(schema, "docs/nested/api.md")
    end

    test "rejects other files and traversal", %{schema: schema} do
      refute Schema.allowed_path?(schema, "lib/foo.ex")
      refute Schema.allowed_path?(schema, "docs")
      refute Schema.allowed_path?(schema, "docs/../README.md")
      refute Schema.allowed_path?(schema, "docs/../../etc/passwd")
      refute Schema.allowed_path?(schema, "/docs/a.md")
      refute Schema.allowed_path?(schema, "docs\\a.md")
      refute Schema.allowed_path?(schema, nil)
    end
  end

  describe "to_map/1" do
    test "produces string keys for Project.docs_schema" do
      {:ok, schema} = Schema.parse(@valid)
      map = Schema.to_map(schema)

      assert map["index_file"] == "README.md"
      assert map["docs_dir"] == "docs"

      assert [%{"name" => "Overview", "required" => true, "max_words" => 200} | _] =
               map["sections"]
    end
  end

  describe "doc_roots/1" do
    test "returns the index file and docs directory" do
      {:ok, schema} = Schema.parse(@valid)
      assert Schema.doc_roots(schema) == ["README.md", "docs"]
    end
  end

  defp parse_with_index(index_file) do
    Schema.parse("""
    index_file: #{index_file}
    sections:
      - name: Overview
    """)
  end

  defp parse_with_docs_dir(docs_dir) do
    Schema.parse("""
    index_file: README.md
    docs_dir: #{docs_dir}
    sections:
      - name: Overview
    """)
  end
end
