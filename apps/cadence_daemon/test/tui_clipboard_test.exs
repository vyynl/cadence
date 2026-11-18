defmodule Cadence.Daemon.TUI.ClipboardTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Cadence.Daemon.TUI.Clipboard

  test "osc52/1 wraps the base64 text in the OSC 52 escape" do
    assert Clipboard.osc52("https://example.test/proposals/abc") ==
             "\e]52;c;" <> Base.encode64("https://example.test/proposals/abc") <> "\a"
  end

  test "osc52/1 handles an empty payload" do
    assert Clipboard.osc52("") == "\e]52;c;\a"
  end

  test "copy/1 writes the escape to standard output" do
    output = capture_io(fn -> assert Clipboard.copy("hello") == :ok end)
    assert output == Clipboard.osc52("hello")
  end
end
