defmodule Cadence.Shared.GlobTest do
  use ExUnit.Case, async: true

  alias Cadence.Shared.Glob

  describe "match?/2" do
    test "matches a literal path exactly" do
      assert Glob.match?("README.md", "README.md")
      refute Glob.match?("README.md", "docs/README.md")
      refute Glob.match?("README.md", "README.md.bak")
    end

    test "**/ matches zero or more path segments" do
      assert Glob.match?("lib/**/*.ex", "lib/foo.ex")
      assert Glob.match?("lib/**/*.ex", "lib/a/foo.ex")
      assert Glob.match?("lib/**/*.ex", "lib/a/b/foo.ex")
      refute Glob.match?("lib/**/*.ex", "test/foo.ex")
      refute Glob.match?("lib/**/*.ex", "lib/foo.exs")
      refute Glob.match?("lib/**/*.ex", "lib/foo.ex/extra")
    end

    test "** without a trailing slash crosses directories" do
      assert Glob.match?("docs/**", "docs/a.md")
      assert Glob.match?("docs/**", "docs/nested/a.md")
      refute Glob.match?("docs/**", "docs")
      refute Glob.match?("docs/**", "other/docs/a.md")
    end

    test "* does not cross a slash" do
      assert Glob.match?("docs/*.md", "docs/a.md")
      refute Glob.match?("docs/*.md", "docs/nested/a.md")
      assert Glob.match?("*", "README.md")
      refute Glob.match?("*", "docs/README.md")
    end

    test "? matches exactly one non-slash character" do
      assert Glob.match?("v?.md", "v1.md")
      refute Glob.match?("v?.md", "v10.md")
      refute Glob.match?("v?.md", "v/.md")
    end

    test "escapes regex metacharacters in literals" do
      assert Glob.match?("docs/a+b.md", "docs/a+b.md")
      refute Glob.match?("docs/a+b.md", "docs/aab.md")
      assert Glob.match?("lib/foo.ex", "lib/foo.ex")
      refute Glob.match?("lib/foo.ex", "lib/fooXex")
    end

    test "non-binary inputs never match" do
      refute Glob.match?(nil, "a")
      refute Glob.match?("a", nil)
      refute Glob.match?(123, "a")
    end
  end

  describe "compile/1" do
    test "rejects an empty pattern" do
      assert Glob.compile("") == {:error, :empty_pattern}
    end

    test "compiles a valid pattern" do
      assert {:ok, %Regex{}} = Glob.compile("lib/**/*.ex")
    end
  end
end
