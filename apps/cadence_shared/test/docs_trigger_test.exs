defmodule Cadence.Shared.Docs.TriggerTest do
  use ExUnit.Case, async: true

  alias Cadence.Shared.Docs.Schema
  alias Cadence.Shared.Docs.Trigger

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

  describe "reasons/2" do
    test "runs when a generated_from path changed", %{schema: schema} do
      changes = [change("lib/cadence/foo.ex", "", "plain text")]

      assert Trigger.reasons(schema, changes) == {:run, [:generated_from]}
    end

    test "generated_from matches deleted paths", %{schema: schema} do
      changes = [change("lib/cadence/foo.ex", "plain text", nil)]

      assert Trigger.reasons(schema, changes) == {:run, [:generated_from]}
    end

    test "runs when the schema file changed", %{schema: schema} do
      changes = [change(".caddocs.yaml", "", "index_file: README.md")]

      assert Trigger.reasons(schema, changes) == {:run, [:schema_changed]}
    end

    test "runs when an exported function changed", %{schema: schema} do
      changes = [change("test/foo.ex", "defmodule Foo do\nend", "def hello, do: :world")]

      assert Trigger.reasons(schema, changes) == {:run, [:api_surface]}
    end

    test "runs when a module attribute changed", %{schema: schema} do
      changes = [
        change("test/foo.ex", "defmodule Foo do\nend", "@moduledoc \"new\"\n")
      ]

      assert Trigger.reasons(schema, changes) == {:run, [:api_surface]}
    end

    test "runs when an exported function is removed", %{schema: schema} do
      changes = [change("test/foo.ex", "def old, do: :x", "defmodule Foo do\nend")]

      assert Trigger.reasons(schema, changes) == {:run, [:api_surface]}
    end

    test "ignores private functions and unchanged API lines", %{schema: schema} do
      changes = [
        change(
          "test/foo_test.exs",
          "def hello, do: :world\n",
          "def hello, do: :world\ndefp helper, do: :ok\n"
        )
      ]

      assert Trigger.reasons(schema, changes) == :skip
    end

    test "ignores non-Elixir files and docs-only changes", %{schema: schema} do
      changes = [
        change("docs/guide.md", "# Old", "# New\ndef not_code, do: :x"),
        change("README.md", "", "## Overview\n")
      ]

      assert Trigger.reasons(schema, changes) == :skip
    end

    test "combines reasons in a stable order", %{schema: schema} do
      changes = [
        change(".caddocs.yaml", "", "sections: []"),
        change("lib/cadence/foo.ex", "", "def hello, do: :world")
      ]

      assert Trigger.reasons(schema, changes) ==
               {:run, [:schema_changed, :generated_from, :api_surface]}
    end

    test "binary content never crashes the API heuristic", %{schema: schema} do
      changes = [change("test/foo.ex", <<0, 1, 2>>, <<0, 3, 4>>)]

      assert Trigger.reasons(schema, changes) == :skip
    end

    test "non-change input is a skip", %{schema: schema} do
      assert Trigger.reasons(schema, []) == :skip
      assert Trigger.reasons(schema, nil) == :skip
    end
  end

  defp change(path, old_content, new_content) do
    %{
      path: path,
      status: status(old_content, new_content),
      old_content: old_content,
      new_content: new_content
    }
  end

  defp status(nil, _new), do: :added
  defp status(_old, nil), do: :deleted
  defp status(_old, _new), do: :modified
end
