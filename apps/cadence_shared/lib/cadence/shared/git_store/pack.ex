defmodule Cadence.Shared.GitStore.Pack do
  @moduledoc """
  Git packfile v2 encoding and reading.

  A pack stores many objects in one file: a 12-byte header (`PACK`, version 2,
  object count), one entry per object, and a 20-byte SHA-1 trailer over
  everything before it. Entries are either full (commit/tree/blob) or deltas
  (`ofs-delta` referencing an earlier entry by distance, or `ref-delta`
  referencing a base SHA). Entry payloads are zlib-compressed; a delta entry's
  header size is the uncompressed delta size, not the result size.

  Cadence writes ofs-deltas and reads both kinds. Reads are offset-addressed
  through `Pack.Index`, so a pack is never scanned sequentially: the caller
  supplies the decoded offsets (and, when available, `entry_ends/2`) and the
  reader inflates exactly the entry slice. There are no thin packs: a ref-delta
  base must be in the same pack. There are no tags (spec §13, §14).

  Reads validate the zlib stream and the declared size, not the object SHA;
  `GitStore.pack_objects/3` verifies SHA→content while writing a pack, and the
  server repacker verifies before deleting loose copies.
  """

  import Bitwise

  alias Cadence.Shared.GitStore.Pack.Delta

  @pack_magic "PACK"
  @pack_version 2
  @pack_header_bytes 12
  @checksum_bytes 20
  @max_depth 50
  @delta_window 1
  @delta_margin 24
  @delta_min_bytes 64
  @max_delta_bytes 4_194_304
  @max_object_bytes 536_870_912
  @inflate_chunk 8_192
  @header_probe 64

  @type_ofs_delta 6
  @type_ref_delta 7

  @type object :: %{sha: String.t(), type: :blob | :tree | :commit, data: binary()}
  @type entry :: %{
          sha: String.t(),
          type: atom(),
          stored_type: atom(),
          offset: non_neg_integer(),
          crc: non_neg_integer(),
          size: non_neg_integer()
        }
  @type encoded :: %{pack: binary(), checksum: binary(), entries: [entry()]}
  @type reason ::
          :not_found
          | :unexpected_eof
          | :invalid_zlib
          | :invalid_entry_header
          | :invalid_delta_base
          | :delta_chain_too_deep
          | :unsupported_type
          | :size_mismatch
          | :too_large
          | term()

  @doc """
  Encode `objects` into a pack.

  Objects are written in the given order (a delta base must appear before its
  delta); duplicate SHAs are dropped. Blobs may be stored as an ofs-delta
  against one of the previous `:delta_window` blobs (default 1) when the
  compressed delta is meaningfully smaller and the chain stays under the
  reader's depth cap. The returned `entries` carry the offset and CRC needed to
  build the matching index.

  Inputs are expected to be validated (`%{sha, type, data}` with an atom type
  and a SHA that matches the content); `GitStore.pack_objects/3` does that.
  """
  @spec encode([object()], keyword()) :: {:ok, encoded()}
  def encode(objects, opts \\ []) when is_list(objects) do
    window = max(Keyword.get(opts, :delta_window, @delta_window), 1)
    objects = Enum.uniq_by(objects, & &1.sha)

    {acc, _offset, _blobs, entries} =
      Enum.reduce(objects, {[], @pack_header_bytes, [], []}, fn object,
                                                                {acc, offset, blobs, entries} ->
        {stored_type, header_size, payload, base, depth} =
          choose_entry(object, blobs, offset, window)

        entry = entry_binary(stored_type, header_size, base, payload)
        crc = :erlang.crc32(entry)

        meta = %{
          sha: object.sha,
          type: object.type,
          stored_type: stored_type_name(stored_type),
          offset: offset,
          crc: crc,
          size: byte_size(object.data)
        }

        blobs =
          if object.type == :blob and byte_size(object.data) <= @max_delta_bytes do
            [{offset, object.data, depth} | Enum.take(blobs, max(window - 1, 0))]
          else
            blobs
          end

        {[entry | acc], offset + byte_size(entry), blobs, [meta | entries]}
      end)

    body =
      IO.iodata_to_binary([
        @pack_magic,
        <<@pack_version::32-big>>,
        <<length(objects)::32-big>>,
        Enum.reverse(acc)
      ])

    checksum = :crypto.hash(:sha, body)

    {:ok, %{pack: body <> checksum, checksum: checksum, entries: Enum.reverse(entries)}}
  end

  @doc """
  Read an object from a pack by SHA.

  `offsets` is the decoded index map (`sha => offset`). Options:

    * `:ends` — the map from `entry_ends/2`; computed from `offsets` when
      absent. Passing it avoids an O(n log n) rebuild on every read.
    * `:max_depth` — delta-chain limit (default 50).
    * `:max_object_bytes` — reject a declared object larger than this before
      inflating (default 512 MiB).

  Deltas are resolved through the same pack; a missing base, a cycle, or a
  depth over `:max_depth` returns an error instead of recursing forever.
  """
  @spec read_object(Path.t(), %{String.t() => non_neg_integer()}, String.t(), keyword()) ::
          {:ok, {atom(), binary()}} | {:error, reason()}
  def read_object(pack_path, offsets, sha, opts \\ []) when is_map(offsets) do
    max_depth = Keyword.get(opts, :max_depth, @max_depth)
    max_object = Keyword.get(opts, :max_object_bytes, @max_object_bytes)

    with {:ok, offset} <- fetch_offset(offsets, sha),
         {:ok, size} <- file_size(pack_path) do
      ends =
        case Keyword.get(opts, :ends) do
          %{} = ends -> ends
          _ -> entry_ends(offsets, size)
        end

      with_file(pack_path, fn io ->
        resolve(io, size, offsets, ends, offset, 0, max_depth, max_object)
      end)
    end
  end

  @doc """
  Map each entry offset to the byte where its compressed slice ends.

  Entries are contiguous, so an entry ends at the next offset (or at the pack
  trailer). Precomputing this once per pack turns `read_object/4` into O(1)
  slice lookup instead of an O(n) scan per object.
  """
  @spec entry_ends(%{String.t() => non_neg_integer()}, non_neg_integer()) ::
          %{non_neg_integer() => non_neg_integer()}
  def entry_ends(offsets, file_size) do
    limit = max(file_size - @checksum_bytes, 0)

    case offsets |> Map.values() |> Enum.filter(&is_integer/1) |> Enum.sort() do
      [] ->
        %{}

      [_ | _] = sorted ->
        sorted
        |> Enum.zip(tl(sorted) ++ [limit])
        |> Map.new(fn {offset, next} -> {offset, min(next, limit)} end)
    end
  end

  @doc """
  Encode an entry header (type and size varint).

  Exposed for tests that build known-byte fixtures.
  """
  @spec entry_header(atom() | non_neg_integer(), non_neg_integer()) :: binary()
  def entry_header(:commit, size), do: entry_header(1, size)
  def entry_header(:tree, size), do: entry_header(2, size)
  def entry_header(:blob, size), do: entry_header(3, size)

  def entry_header(type, size) when is_integer(type) and size >= 0 do
    first = (type &&& 0x07) <<< 4 ||| (size &&& 0x0F)
    rest = size >>> 4

    if rest == 0 do
      <<first>>
    else
      <<first ||| 0x80>> <> Delta.encode_varint(rest)
    end
  end

  @doc "Encode an ofs-delta base distance (Git's decrementing 7-bit varint)."
  @spec ofs_delta_offset(pos_integer()) :: binary()
  def ofs_delta_offset(value) when value > 0 do
    encode_ofs(value, [value &&& 0x7F])
  end

  ## Encode

  defp choose_entry(%{type: type, data: data}, blobs, offset, window)
       when type in [:commit, :tree, :blob] do
    compressed_full = :zlib.compress(data)
    full = {full_type(type), byte_size(data), compressed_full, nil, 0}

    candidates =
      if type == :blob and byte_size(data) >= @delta_min_bytes and
           byte_size(data) <= @max_delta_bytes do
        blobs
        |> Enum.take(window)
        |> Enum.filter(fn {_offset, _base, depth} -> depth < @max_depth end)
      else
        []
      end

    case best_delta(candidates, data, compressed_full) do
      nil ->
        full

      {base_offset, base_depth, delta, compressed_delta} ->
        {@type_ofs_delta, byte_size(delta), compressed_delta, {:ofs, offset - base_offset},
         base_depth + 1}
    end
  end

  defp best_delta([], _data, _compressed_full), do: nil

  defp best_delta(candidates, data, compressed_full) do
    candidates
    |> Enum.map(fn {base_offset, base_data, base_depth} ->
      {:ok, delta} = Delta.build(base_data, data)
      {base_offset, base_depth, delta, :zlib.compress(delta)}
    end)
    |> Enum.filter(fn {_offset, _depth, delta, compressed_delta} ->
      byte_size(compressed_delta) + @delta_margin < byte_size(compressed_full) and
        byte_size(delta) < byte_size(data)
    end)
    |> Enum.min_by(fn {_offset, _depth, _delta, compressed} -> byte_size(compressed) end, fn ->
      nil
    end)
  end

  defp entry_binary(type, size, base, payload) do
    entry_header(type, size) <> base_binary(base) <> payload
  end

  defp base_binary(nil), do: ""

  defp base_binary({:ofs, distance}) when distance > 0, do: ofs_delta_offset(distance)

  defp base_binary({:ref, sha}) when is_binary(sha) and byte_size(sha) == 40 do
    Base.decode16!(sha, case: :mixed)
  end

  defp full_type(:commit), do: 1
  defp full_type(:tree), do: 2
  defp full_type(:blob), do: 3

  defp stored_type_name(@type_ofs_delta), do: :ofs_delta
  defp stored_type_name(@type_ref_delta), do: :ref_delta
  defp stored_type_name(1), do: :commit
  defp stored_type_name(2), do: :tree
  defp stored_type_name(3), do: :blob

  defp encode_ofs(value, acc) do
    shifted = value >>> 7

    if shifted == 0 do
      :erlang.list_to_binary(acc)
    else
      shifted = shifted - 1
      encode_ofs(shifted, [0x80 ||| (shifted &&& 0x7F) | acc])
    end
  end

  ## Read

  defp resolve(_io, _file_size, _offsets, _ends, _offset, depth, max_depth, _max_object)
       when depth > max_depth,
       do: {:error, :delta_chain_too_deep}

  defp resolve(io, file_size, offsets, ends, offset, depth, max_depth, max_object)
       when offset >= 0 and offset < file_size do
    with {:ok, header} <- pread(io, offset, @header_probe),
         {:ok, type, size, header_len, rest} <- decode_entry_header(header) do
      resolve_entry(
        io,
        file_size,
        offsets,
        ends,
        offset,
        depth,
        max_depth,
        max_object,
        type,
        size,
        header_len,
        rest
      )
    end
  end

  defp resolve(_io, _file_size, _offsets, _ends, _offset, _depth, _max_depth, _max_object),
    do: {:error, :not_found}

  defp resolve_entry(
         io,
         file_size,
         _offsets,
         ends,
         offset,
         _depth,
         _max_depth,
         max_object,
         type,
         size,
         header_len,
         _rest
       )
       when type in [1, 2, 3] do
    data_end = entry_end(ends, offset, file_size)

    with :ok <- check_size(size, max_object),
         {:ok, data} <- inflate_at(io, offset + header_len, size, data_end) do
      {:ok, {stored_type_name(type), data}}
    end
  end

  defp resolve_entry(
         io,
         file_size,
         offsets,
         ends,
         offset,
         depth,
         max_depth,
         max_object,
         @type_ofs_delta,
         size,
         header_len,
         rest
       ) do
    data_end = entry_end(ends, offset, file_size)

    with :ok <- check_size(size, max_object),
         {:ok, distance, ofs_len} <- decode_ofs(rest, 0, 0),
         base_offset = offset - distance,
         true <- base_offset >= 0 and base_offset < offset,
         {:ok, base} <-
           resolve(io, file_size, offsets, ends, base_offset, depth + 1, max_depth, max_object),
         {:ok, delta} <- inflate_at(io, offset + header_len + ofs_len, size, data_end),
         {:ok, data} <- Delta.apply(elem(base, 1), delta, max_result_bytes: max_object) do
      {:ok, {elem(base, 0), data}}
    else
      false -> {:error, :invalid_delta_base}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_entry(
         io,
         file_size,
         offsets,
         ends,
         offset,
         depth,
         max_depth,
         max_object,
         @type_ref_delta,
         size,
         header_len,
         rest
       ) do
    case rest do
      <<base_sha::binary-size(20), _rest::binary>> ->
        base_hex = Base.encode16(base_sha, case: :lower)
        data_end = entry_end(ends, offset, file_size)

        with :ok <- check_size(size, max_object),
             {:ok, base_offset} <- fetch_offset(offsets, base_hex),
             true <- base_offset < offset,
             {:ok, base} <-
               resolve(
                 io,
                 file_size,
                 offsets,
                 ends,
                 base_offset,
                 depth + 1,
                 max_depth,
                 max_object
               ),
             {:ok, delta} <- inflate_at(io, offset + header_len + 20, size, data_end),
             {:ok, data} <- Delta.apply(elem(base, 1), delta, max_result_bytes: max_object) do
          {:ok, {elem(base, 0), data}}
        else
          false -> {:error, :invalid_delta_base}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :invalid_entry_header}
    end
  end

  defp resolve_entry(
         _io,
         _file_size,
         _offsets,
         _ends,
         _offset,
         _depth,
         _max_depth,
         _max_object,
         _type,
         _size,
         _header_len,
         _rest
       ),
       do: {:error, :unsupported_type}

  defp decode_entry_header(<<first, rest::binary>>) do
    type = first >>> 4 &&& 0x07
    size_low = first &&& 0x0F

    if (first &&& 0x80) == 0 do
      {:ok, type, size_low, 1, rest}
    else
      case decode_size(rest, size_low, 4, 1) do
        {:ok, size, rest, consumed} -> {:ok, type, size, consumed, rest}
        :error -> {:error, :invalid_entry_header}
      end
    end
  end

  defp decode_entry_header(_bin), do: {:error, :invalid_entry_header}

  defp decode_size(<<byte, rest::binary>>, acc, shift, consumed) when shift <= 56 do
    acc = acc ||| (byte &&& 0x7F) <<< shift

    if (byte &&& 0x80) == 0 do
      {:ok, acc, rest, consumed + 1}
    else
      decode_size(rest, acc, shift + 7, consumed + 1)
    end
  end

  defp decode_size(_bin, _acc, _shift, _consumed), do: :error

  defp decode_ofs(<<byte, rest::binary>>, acc, consumed) when consumed < 10 do
    acc = acc ||| (byte &&& 0x7F)

    if (byte &&& 0x80) == 0 do
      {:ok, acc, consumed + 1}
    else
      decode_ofs(rest, (acc + 1) <<< 7, consumed + 1)
    end
  end

  defp decode_ofs(_bin, _acc, _consumed), do: {:error, :invalid_delta_base}

  defp entry_end(ends, offset, file_size) do
    Map.get(ends, offset, file_size - @checksum_bytes)
  end

  defp check_size(size, max_object) do
    if size <= max_object, do: :ok, else: {:error, :too_large}
  end

  defp inflate_at(io, start, expected, data_end) do
    length = data_end - start

    cond do
      length <= 0 ->
        {:error, :unexpected_eof}

      true ->
        with {:ok, data} <- pread(io, start, length) do
          inflate_capped(data, expected)
        end
    end
  end

  # Feed the exact compressed slice in bounded chunks and stop as soon as the
  # output exceeds the declared size, so a hostile stream cannot force a large
  # allocation before the size check.
  defp inflate_capped(data, expected) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z)

      case consume_chunks(z, data, expected, [], 0) do
        {:ok, acc, produced} ->
          finish_inflate(z, expected, acc, produced)

        {:error, _reason} = error ->
          error
      end
    rescue
      _ -> {:error, :invalid_zlib}
    catch
      _, _ -> {:error, :invalid_zlib}
    after
      :zlib.close(z)
    end
  end

  defp consume_chunks(_z, "", _expected, acc, produced), do: {:ok, acc, produced}

  defp consume_chunks(z, data, expected, acc, produced) do
    take = min(byte_size(data), @inflate_chunk)
    <<chunk::binary-size(^take), rest::binary>> = data
    {_status, output} = :zlib.safeInflate(z, chunk)
    output = IO.iodata_to_binary(output)
    produced = produced + byte_size(output)

    if produced > expected do
      {:error, :size_mismatch}
    else
      consume_chunks(z, rest, expected, [acc, output], produced)
    end
  end

  # `safeInflate/2` is allowed to return before the stream end (and to leave
  # input queued), so drain it with `safeInflate(z, [])` one chunk at a time.
  # Never use `:zlib.inflate(z, [])` here: it would flush everything at once.
  # Requiring `:finished` keeps zlib's Adler-32 end check.
  defp finish_inflate(z, expected, acc, produced) do
    case :zlib.safeInflate(z, []) do
      {:finished, output} ->
        output = IO.iodata_to_binary(output)
        total = produced + byte_size(output)

        if total == expected do
          {:ok, IO.iodata_to_binary([acc, output])}
        else
          {:error, :size_mismatch}
        end

      {:continue, output} ->
        output = IO.iodata_to_binary(output)
        total = produced + byte_size(output)

        cond do
          total > expected -> {:error, :size_mismatch}
          output == "" -> {:error, :size_mismatch}
          true -> finish_inflate(z, expected, [acc, output], total)
        end
    end
  end

  defp fetch_offset(offsets, sha) do
    case Map.fetch(offsets, sha) do
      {:ok, offset} when is_integer(offset) and offset >= 0 -> {:ok, offset}
      _ -> {:error, :not_found}
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> {:ok, size}
      {:error, reason} -> {:error, reason}
    end
  end

  defp with_file(path, fun) do
    case File.open(path, [:read, :binary, :raw], fun) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp pread(io, offset, length) do
    case :file.pread(io, offset, length) do
      {:ok, data} -> {:ok, data}
      :eof -> {:error, :unexpected_eof}
      {:error, reason} -> {:error, reason}
    end
  end
end
