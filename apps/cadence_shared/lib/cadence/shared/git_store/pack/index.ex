defmodule Cadence.Shared.GitStore.Pack.Index do
  @moduledoc """
  Git pack index v2 (`objects/pack/pack-<sha>.idx`) encoding and decoding.

  The index is the lookup table a reader needs: a SHA-1 is found through a
  256-entry fanout table, then a sorted SHA list, then a 32-bit offset (or an
  index into a 64-bit offset table). The file ends with the pack checksum and
  the index checksum, both SHA-1 over everything preceding them.

  Cadence writes the index itself and never shells out to `git`; this module is
  the only place that knows the byte layout (spec §13 Phase 7, §14).
  """

  import Bitwise

  @magic <<0xFF, "tOc">>
  @version 2
  @fanout_entries 256
  @fanout_bytes @fanout_entries * 4
  @sha_bytes 20
  @checksum_bytes 20
  @large_offset_flag 0x80000000

  @type entry :: %{sha: String.t(), offset: non_neg_integer(), crc: non_neg_integer()}
  @type t :: %{
          offsets: %{String.t() => non_neg_integer()},
          crcs: %{String.t() => non_neg_integer()},
          pack_checksum: binary()
        }

  @doc """
  Encode an index for `entries` (sorted internally by SHA).

  `pack_checksum` is the 20-byte trailer of the pack this index describes.
  Returns the raw index file bytes.
  """
  @spec encode([entry()], binary()) :: binary()
  def encode(entries, pack_checksum)
      when is_list(entries) and is_binary(pack_checksum) and
             byte_size(pack_checksum) == @checksum_bytes do
    sorted = Enum.sort_by(entries, &decode_sha!(&1.sha))

    raw_shas = Enum.map(sorted, &decode_sha!(&1.sha))
    fanout = fanout(raw_shas)
    crcs = Enum.map(sorted, &<<&1.crc::32-big>>)
    {offset_words, large_offsets} = encode_offsets(sorted)

    body =
      IO.iodata_to_binary([
        @magic,
        <<@version::32-big>>,
        fanout,
        raw_shas,
        crcs,
        offset_words,
        large_offsets,
        pack_checksum
      ])

    body <> sha1(body)
  end

  @doc """
  Decode index bytes.

  Validates the magic/version, fanout monotonicity and counts, sorted SHA
  ordering, offset-table bounds, and both checksums. Returns
  `{:error, reason}` for any malformed input; never raises.
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, atom()}
  def decode(<<0xFF, "tOc", @version::32-big, rest::binary>> = bytes)
      when byte_size(rest) >= @fanout_bytes + @checksum_bytes do
    payload = binary_part(bytes, 0, byte_size(bytes) - @checksum_bytes)
    checksum = binary_part(bytes, byte_size(bytes) - @checksum_bytes, @checksum_bytes)
    body = binary_part(rest, 0, byte_size(rest) - @checksum_bytes)

    with true <- sha1(payload) == checksum,
         {:ok, index} <- decode_payload(body) do
      {:ok, index}
    else
      false -> {:error, :invalid_index_checksum}
      {:error, reason} -> {:error, reason}
    end
  end

  def decode(<<0xFF, "tOc", @version::32-big, _rest::binary>>),
    do: {:error, :truncated_index}

  def decode(<<0xFF, "tOc", _version::32-big, _rest::binary>>),
    do: {:error, :unsupported_index_version}

  def decode(_bytes), do: {:error, :invalid_index_magic}

  @doc "Look up a SHA in a decoded index, returning its pack offset or `nil`."
  @spec offset(t(), String.t()) :: non_neg_integer() | nil
  def offset(%{offsets: offsets}, sha), do: Map.get(offsets, sha)

  @doc "Path of the `.pack` file that pairs with an `.idx` path."
  @spec pack_path(Path.t()) :: Path.t()
  def pack_path(idx_path), do: Path.rootname(idx_path) <> ".pack"

  ## Decode

  defp decode_payload(payload) do
    <<fanout_bin::binary-size(@fanout_bytes), tail::binary>> = payload

    with {:ok, fanout} <- decode_fanout(fanout_bin),
         count = List.last(fanout),
         {:ok, sections} <- split_sections(tail, count),
         {:ok, shas} <- decode_shas(sections.shas),
         :ok <- validate_fanout(fanout, shas),
         :ok <- validate_sorted(shas),
         :ok <- validate_unique(shas),
         {:ok, crcs} <- decode_crcs(sections.crcs, count),
         {:ok, all_offsets} <- decode_offsets(sections.offsets, sections.large, count) do
      sha_hexes = Enum.map(shas, &Base.encode16(&1, case: :lower))

      {:ok,
       %{
         offsets: Map.new(Enum.zip(sha_hexes, all_offsets)),
         crcs: Map.new(Enum.zip(sha_hexes, crcs)),
         pack_checksum: sections.pack_checksum
       }}
    end
  end

  defp split_sections(tail, count) do
    sha_len = count * @sha_bytes
    crc_len = count * 4
    offset_len = count * 4
    fixed = sha_len + crc_len + offset_len + @checksum_bytes

    if byte_size(tail) < fixed do
      {:error, :truncated_index}
    else
      large_len = byte_size(tail) - fixed

      if rem(large_len, 8) != 0 do
        {:error, :invalid_large_offset_table}
      else
        <<shas::binary-size(^sha_len), crcs::binary-size(^crc_len),
          offsets::binary-size(^offset_len), large::binary-size(^large_len),
          pack_checksum::binary-size(@checksum_bytes)>> = tail

        {:ok,
         %{
           shas: shas,
           crcs: crcs,
           offsets: offsets,
           large: large,
           pack_checksum: pack_checksum
         }}
      end
    end
  end

  defp decode_fanout(bin) do
    values = for <<value::32-big <- bin>>, do: value

    if length(values) == @fanout_entries and monotonic?(values) do
      {:ok, values}
    else
      {:error, :invalid_fanout}
    end
  end

  defp monotonic?(values), do: values == Enum.sort(values)

  defp validate_fanout(fanout, shas) do
    counts = Enum.frequencies_by(shas, fn <<byte, _::binary>> -> byte end)

    expected =
      Enum.scan(0..(@fanout_entries - 1), 0, fn byte, acc ->
        acc + Map.get(counts, byte, 0)
      end)

    if fanout == expected, do: :ok, else: {:error, :invalid_fanout}
  end

  defp validate_sorted(shas) do
    if shas == Enum.sort(shas), do: :ok, else: {:error, :unsorted_shas}
  end

  defp validate_unique(shas) do
    if shas == Enum.uniq(shas), do: :ok, else: {:error, :duplicate_shas}
  end

  defp decode_shas(bin) do
    if rem(byte_size(bin), @sha_bytes) == 0 do
      {:ok, for(<<sha::binary-size(@sha_bytes) <- bin>>, do: sha)}
    else
      {:error, :invalid_sha_table}
    end
  end

  defp decode_crcs(bin, count) do
    if byte_size(bin) == count * 4 do
      {:ok, for(<<crc::32-big <- bin>>, do: crc)}
    else
      {:error, :invalid_crc_table}
    end
  end

  defp decode_offsets(bin, large_bin, count) do
    words = for <<word::32-big <- bin>>, do: word
    large = for <<offset::64-big <- large_bin>>, do: offset

    Enum.reduce_while(words, {:ok, []}, fn word, {:ok, acc} ->
      if (word &&& @large_offset_flag) == 0 do
        {:cont, {:ok, [word | acc]}}
      else
        index = word &&& 0x7FFFFFFF

        case Enum.fetch(large, index) do
          {:ok, offset} -> {:cont, {:ok, [offset | acc]}}
          :error -> {:halt, {:error, :invalid_large_offset}}
        end
      end
    end)
    |> case do
      {:ok, offsets} when length(offsets) == count -> {:ok, Enum.reverse(offsets)}
      {:ok, _offsets} -> {:error, :invalid_offset_table}
      {:error, reason} -> {:error, reason}
    end
  end

  ## Encode

  defp fanout(shas) do
    counts = Enum.frequencies_by(shas, fn <<byte, _::binary>> -> byte end)

    0..(@fanout_entries - 1)
    |> Enum.map_reduce(0, fn byte, acc ->
      total = acc + Map.get(counts, byte, 0)
      {<<total::32-big>>, total}
    end)
    |> elem(0)
    |> IO.iodata_to_binary()
  end

  defp encode_offsets(entries) do
    {words, large, _count} =
      Enum.reduce(entries, {[], [], 0}, fn %{offset: offset}, {words, large, count} ->
        if offset < @large_offset_flag do
          {[<<offset::32-big>> | words], large, count}
        else
          index = count

          {[<<@large_offset_flag ||| index::32-big>> | words], [<<offset::64-big>> | large],
           count + 1}
        end
      end)

    {Enum.reverse(words), Enum.reverse(large)}
  end

  defp decode_sha!(sha) when is_binary(sha) and byte_size(sha) == 40,
    do: Base.decode16!(sha, case: :mixed)

  defp sha1(data), do: :crypto.hash(:sha, data)
end
