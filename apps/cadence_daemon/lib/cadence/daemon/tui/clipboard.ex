defmodule Cadence.Daemon.TUI.Clipboard do
  @moduledoc """
  Clipboard support over OSC 52.

  The TUI is often driven over SSH, where no local clipboard provider exists.
  OSC 52 asks the *outer* terminal to copy, so it works through a remote
  session without any helper binary.

  `copy/1` writes the escape straight to the group leader; call it after the
  renderer has painted so the escape is not swallowed by a redraw.
  """

  @prefix "\e]52;c;"
  @terminator "\a"

  @doc """
  Returns the OSC 52 copy escape for `text`.

  The payload is Base64 of the plain text, terminated by BEL.
  """
  @spec osc52(String.t()) :: String.t()
  def osc52(text) when is_binary(text) do
    @prefix <> Base.encode64(text) <> @terminator
  end

  @doc "Writes the OSC 52 escape for `text` to standard output."
  @spec copy(String.t()) :: :ok
  def copy(text) when is_binary(text) do
    IO.write(osc52(text))
  end
end
