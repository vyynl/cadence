defmodule Cadence.Shared.UTF8Test do
  use ExUnit.Case, async: true

  alias Cadence.Shared.UTF8

  describe "binary?/1" do
    test "text is not binary" do
      refute UTF8.binary?("hello, wörld\n")
      refute UTF8.binary?("")
    end

    test "invalid UTF-8 is binary" do
      assert UTF8.binary?(<<0xFF, 0xFE>>)
    end

    test "a NUL byte is binary even though it is valid UTF-8" do
      assert String.valid?(<<0, 1, 2>>)
      assert UTF8.binary?(<<0, 1, 2>>)
    end

    test "non-binaries are treated as binary" do
      assert UTF8.binary?(nil)
      assert UTF8.binary?(:atom)
    end
  end

  describe "truncate/2" do
    test "returns short content unchanged" do
      assert UTF8.truncate("hello", 10) == "hello"
      assert UTF8.truncate("hello", 5) == "hello"
    end

    test "never returns more than max_bytes" do
      assert byte_size(UTF8.truncate("hello world", 5)) <= 5
    end

    test "trims an incomplete trailing codepoint" do
      # "é" is two bytes; cutting at 3 leaves one complete é and half of the
      # next one, which must be dropped to stay valid UTF-8.
      truncated = UTF8.truncate("ééé", 3)

      assert truncated == "é"
      assert String.valid?(truncated)
    end

    test "returns an empty prefix for invalid UTF-8" do
      assert UTF8.truncate(<<0xFF, 0xFF>>, 2) == ""
    end

    test "zero or negative budgets return an empty string" do
      assert UTF8.truncate("hello", 0) == ""
      assert UTF8.truncate("hello", -1) == ""
    end
  end
end
