defmodule Cadence.Shared.GitStore.Pack.Delta do
  @moduledoc """
  Git delta encoding (`base size`, `result size`, then copy/insert commands).

  Used by `Cadence.Shared.GitStore.Pack` to store a blob relative to a
  previously packed blob. The builder is a bounded block matcher, not a
  longest-common-subsequence solver: correctness never depends on delta quality,
  only on `apply/3` round-tripping.

  Delta format (see Git's `Documentation/technical/pack-format.adoc`):

    * base size and result size, each a little-endian 7-bit varint;
    * a command byte with the high bit set is a copy: bits 0-3 select offset
      bytes, bits 4-6 select size bytes; size 0 means `0x10000`;
    * a command byte with the high bit clear is an insert of that many
      following bytes (1-127);
    * a zero command byte is invalid.
  """

  import Bitwise

  @block 16
  @max_delta_bytes 4_194_304
  @max_result_bytes 536_870_912
  @max_copy_chunk 0xFFFFFF
  @insert_chunk 127

  @type reason ::
          :invalid_command
          | :truncated_delta
          | :base_size_mismatch
          | :result_size_mismatch
          | :copy_out_of_range
          | :too_large

  @doc """
  Apply `delta` to `base`, returning the reconstructed binary.

  `:max_result_bytes` bounds the declared result size (default 512 MiB); a
  larger declaration is rejected before any allocation.
  """
  @spec apply(binary(), binary(), keyword()) :: {:ok, binary()} | {:error, reason()}
  def apply(base, delta, opts \\ [])

  def apply(base, delta, opts) when is_binary(base) and is_binary(delta) do
    max_result = Keyword.get(opts, :max_result_bytes, @max_result_bytes)

    with {:ok, base_size, rest} <- decode_varint(delta),
         :ok <- check_base_size(base_size, base),
         {:ok, result_size, rest} <- decode_varint(rest),
         :ok <- check_result_size(result_size, max_result),
         {:ok, result} <- run_commands(base, rest, result_size) do
      if byte_size(result) == result_size do
        {:ok, result}
      else
        {:error, :result_size_mismatch}
      end
    end
  end

  def apply(_base, _delta, _opts), do: {:error, :truncated_delta}

  @doc """
  Build a delta that turns `base` into `target`.

  Returns a valid delta for any binary inputs; the caller decides whether it is
  worth storing (pack encoding compares compressed sizes).
  """
  @spec build(binary(), binary()) :: {:ok, binary()}
  def build(base, target) when is_binary(base) and is_binary(target) do
    ops =
      if byte_size(target) > @max_delta_bytes do
        insert_ops(target)
      else
        index = block_index(base)
        {ops, tail} = scan(target, 0, index, base, [], 0)
        Enum.reverse([insert_ops(tail) | ops])
      end

    {:ok,
     IO.iodata_to_binary([
       encode_varint(byte_size(base)),
       encode_varint(byte_size(target)),
       ops
     ])}
  end

  @doc "Encode a delta size (little-endian 7-bit varint)."
  @spec encode_varint(non_neg_integer()) :: binary()
  def encode_varint(value) when value >= 0 do
    value |> encode_varint_chunks([]) |> Enum.reverse() |> :erlang.list_to_binary()
  end

  @doc "Decode a delta size, returning `{:ok, value, rest}`."
  @spec decode_varint(binary()) :: {:ok, non_neg_integer(), binary()} | {:error, :truncated_delta}
  def decode_varint(bin), do: decode_varint(bin, 0, 0)

  ## Apply

  defp check_base_size(size, base) do
    if size == byte_size(base), do: :ok, else: {:error, :base_size_mismatch}
  end

  defp check_result_size(size, max_result) do
    if size <= max_result, do: :ok, else: {:error, :too_large}
  end

  defp run_commands(base, rest, result_size) do
    do_run_commands(base, rest, [], 0, result_size)
  end

  defp do_run_commands(_base, <<>>, acc, produced, expected) do
    if produced == expected do
      {:ok, IO.iodata_to_binary(Enum.reverse(acc))}
    else
      {:error, :result_size_mismatch}
    end
  end

  defp do_run_commands(_base, <<0, _rest::binary>>, _acc, _produced, _expected),
    do: {:error, :invalid_command}

  defp do_run_commands(base, <<cmd, rest::binary>>, acc, produced, expected)
       when (cmd &&& 0x80) != 0 do
    with {:ok, offset, size, rest} <- parse_copy(cmd, rest),
         true <- offset + size <= byte_size(base),
         true <- produced + size <= expected do
      do_run_commands(
        base,
        rest,
        [binary_part(base, offset, size) | acc],
        produced + size,
        expected
      )
    else
      false -> {:error, :copy_out_of_range}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_run_commands(base, <<len, rest::binary>>, acc, produced, expected)
       when len in 1..@insert_chunk do
    cond do
      byte_size(rest) < len ->
        {:error, :truncated_delta}

      produced + len > expected ->
        {:error, :result_size_mismatch}

      true ->
        <<insert::binary-size(^len), rest::binary>> = rest
        do_run_commands(base, rest, [insert | acc], produced + len, expected)
    end
  end

  defp do_run_commands(_base, _rest, _acc, _produced, _expected), do: {:error, :truncated_delta}

  defp parse_copy(cmd, rest) do
    with {:ok, offset, rest} <- read_bytes(rest, 0..3, cmd, 0),
         {:ok, size, rest} <- read_bytes(rest, 4..6, cmd, 4) do
      {:ok, offset, if(size == 0, do: 0x10000, else: size), rest}
    end
  end

  defp read_bytes(rest, range, cmd, base_bit) do
    Enum.reduce_while(range, {:ok, 0, rest}, fn bit, {:ok, acc, rest} ->
      if (cmd &&& 1 <<< bit) == 0 do
        {:cont, {:ok, acc, rest}}
      else
        case rest do
          <<byte, rest::binary>> ->
            {:cont, {:ok, acc ||| byte <<< (8 * (bit - base_bit)), rest}}

          <<>> ->
            {:halt, {:error, :truncated_delta}}
        end
      end
    end)
  end

  ## Build

  # Base block -> first offset. `Map.put_new` keeps the index bounded on
  # repetitive content (the first occurrence is enough to start a match).
  defp block_index(base) do
    last = byte_size(base) - @block

    if last < 0 do
      %{}
    else
      0..last
      |> Enum.take_every(@block)
      |> Enum.reduce(%{}, fn offset, acc ->
        Map.put_new(acc, binary_part(base, offset, @block), offset)
      end)
    end
  end

  # `pending_start` is where the current run of unmatched bytes began; the run
  # is materialized only when a match is found or at the tail. This avoids
  # building one sub-binary per unmatched byte.
  defp scan(target, pos, index, base, ops, pending_start) do
    size = byte_size(target)

    cond do
      pos + @block > size ->
        tail = binary_part(target, pending_start, size - pending_start)
        {ops, tail}

      match = Map.get(index, binary_part(target, pos, @block)) ->
        length = match_length(base, match, target, pos)
        insert = insert_ops(binary_part(target, pending_start, pos - pending_start))
        copy = copy_ops(match, length)
        scan(target, pos + length, index, base, [copy, insert | ops], pos + length)

      true ->
        scan(target, pos + 1, index, base, ops, pending_start)
    end
  end

  defp match_length(base, base_offset, target, target_offset) do
    max = min(byte_size(base) - base_offset, byte_size(target) - target_offset)
    count_equal(base, base_offset, target, target_offset, 0, max)
  end

  defp count_equal(_base, _bo, _target, _to, count, max) when count >= max, do: count

  defp count_equal(base, bo, target, to, count, max) do
    chunk = min(@block, max - count)

    if binary_part(base, bo + count, chunk) == binary_part(target, to + count, chunk) do
      count_equal(base, bo, target, to, count + chunk, max)
    else
      count_bytes(base, bo, target, to, count, max)
    end
  end

  defp count_bytes(_base, _bo, _target, _to, count, max) when count >= max, do: count

  defp count_bytes(base, bo, target, to, count, max) do
    if :binary.at(base, bo + count) == :binary.at(target, to + count) do
      count_bytes(base, bo, target, to, count + 1, max)
    else
      count
    end
  end

  # Copy commands carry at most 0xFFFFFF bytes each; the offset advances with
  # every chunk so a long match is still one contiguous copy.
  defp copy_ops(offset, size) when size > 0 do
    {chunks, _next} =
      size
      |> copy_chunks()
      |> Enum.map_reduce(offset, fn chunk, next_offset ->
        {encode_copy(next_offset, chunk), next_offset + chunk}
      end)

    IO.iodata_to_binary(chunks)
  end

  defp copy_ops(_offset, _size), do: ""

  defp copy_chunks(size), do: copy_chunks(size, [])

  defp copy_chunks(0, acc), do: Enum.reverse(acc)

  defp copy_chunks(size, acc) do
    chunk = min(size, @max_copy_chunk)
    copy_chunks(size - chunk, [chunk | acc])
  end

  defp encode_copy(offset, size) do
    {offset_flags, offset_bytes} = encode_bytes(offset, 4, 0)
    {size_flags, size_bytes} = encode_bytes(size, 3, 4)
    <<0x80 ||| offset_flags ||| size_flags>> <> IO.iodata_to_binary([offset_bytes, size_bytes])
  end

  defp encode_bytes(value, count, flag_offset) do
    0..(count - 1)
    |> Enum.reduce({0, []}, fn index, {flags, bytes} ->
      byte = value >>> (8 * index) &&& 0xFF

      if byte == 0 do
        {flags, bytes}
      else
        {flags ||| 1 <<< (flag_offset + index), [byte | bytes]}
      end
    end)
    |> then(fn {flags, bytes} -> {flags, Enum.reverse(bytes)} end)
  end

  defp insert_ops(""), do: ""

  defp insert_ops(data) do
    data
    |> chunk_binary(@insert_chunk)
    |> Enum.map(fn chunk -> <<byte_size(chunk)>> <> chunk end)
    |> IO.iodata_to_binary()
  end

  defp chunk_binary(data, size), do: chunk_binary(data, size, [])

  defp chunk_binary("", _size, acc), do: Enum.reverse(acc)

  defp chunk_binary(data, size, acc) do
    take = min(size, byte_size(data))
    <<chunk::binary-size(^take), rest::binary>> = data
    chunk_binary(rest, size, [chunk | acc])
  end

  ## Varint

  defp encode_varint_chunks(value, acc) when value < 0x80 do
    [value | acc]
  end

  defp encode_varint_chunks(value, acc) do
    encode_varint_chunks(value >>> 7, [(value &&& 0x7F) ||| 0x80 | acc])
  end

  defp decode_varint(<<byte, rest::binary>>, value, shift) when shift <= 56 do
    value = value ||| (byte &&& 0x7F) <<< shift

    if (byte &&& 0x80) == 0 do
      {:ok, value, rest}
    else
      decode_varint(rest, value, shift + 7)
    end
  end

  defp decode_varint(_bin, _value, _shift), do: {:error, :truncated_delta}
end
