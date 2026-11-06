defmodule Cadence.Shared.UTF8 do
  @moduledoc """
  UTF-8 helpers shared by prompt builders.

  "Binary" in Cadence means *invalid UTF-8 or contains a NUL byte* — the same
  rule Git uses. `String.valid?/1` alone is not enough: NUL and other ASCII
  control bytes are valid UTF-8 codepoints.
  """

  @spec binary?(term()) :: boolean()
  def binary?(content) when is_binary(content) do
    not String.valid?(content) or :binary.match(content, <<0>>) != :nomatch
  end

  def binary?(_content), do: true

  @doc """
  Returns at most `max_bytes` bytes of `content`, trimming an incomplete trailing
  codepoint so the result is always valid UTF-8.

  Only up to three bytes are trimmed (the largest incomplete UTF-8 sequence). If
  the prefix is still invalid, the content is not text; this returns `""` so the
  caller can treat it as binary (`binary?/1`).

  The caller decides whether to append a truncation marker.
  """
  @spec truncate(binary(), non_neg_integer()) :: binary()
  def truncate(content, max_bytes) when is_binary(content) and is_integer(max_bytes) do
    if max_bytes <= 0 do
      ""
    else
      if byte_size(content) <= max_bytes do
        if String.valid?(content), do: content, else: ""
      else
        prefix = binary_part(content, 0, max_bytes)
        valid_prefix(prefix, byte_size(prefix))
      end
    end
  end

  def truncate(_content, _max_bytes), do: ""

  defp valid_prefix(prefix, size) do
    candidate = binary_part(prefix, 0, size)

    if String.valid?(candidate) do
      candidate
    else
      trim_invalid_tail(prefix, size, 3)
    end
  end

  defp trim_invalid_tail(_prefix, _size, 0), do: ""

  defp trim_invalid_tail(prefix, size, attempts) do
    candidate = binary_part(prefix, 0, size - 1)

    if String.valid?(candidate) do
      candidate
    else
      trim_invalid_tail(prefix, size - 1, attempts - 1)
    end
  end
end
