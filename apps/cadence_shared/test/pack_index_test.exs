defmodule Cadence.Shared.GitStore.Pack.IndexTest do
  use ExUnit.Case, async: true

  alias Cadence.Shared.GitStore.Pack.Index

  @checksum :crypto.strong_rand_bytes(20)

  describe "round-trip" do
    test "an empty index" do
      encoded = Index.encode([], @checksum)
      assert {:ok, index} = Index.decode(encoded)
      assert index.offsets == %{}
      assert index.crcs == %{}
      assert index.pack_checksum == @checksum
    end

    test "one entry" do
      [sha] = shas(1)
      entries = [%{sha: sha, offset: 12, crc: :erlang.crc32(sha)}]

      assert {:ok, index} = Index.decode(Index.encode(entries, @checksum))
      assert index.offsets == %{sha => 12}
      assert index.crcs == %{sha => :erlang.crc32(sha)}
      assert Index.offset(index, sha) == 12
      assert Index.offset(index, String.duplicate("0", 40)) == nil
    end

    test "many entries keep SHA ordering and lookups" do
      entries =
        shas(300)
        |> Enum.with_index()
        |> Enum.map(fn {sha, i} -> %{sha: sha, offset: i * 37 + 12, crc: i} end)

      assert {:ok, index} = Index.decode(Index.encode(entries, @checksum))

      for entry <- entries do
        assert Index.offset(index, entry.sha) == entry.offset
        assert index.crcs[entry.sha] == entry.crc
      end
    end

    test "fanout grows across every bucket and lookups survive growth" do
      first_wave =
        for byte <- 0..255 do
          raw = <<byte>> <> binary_part(:crypto.hash(:sha, <<byte>>), 0, 19)
          Base.encode16(raw, case: :lower)
        end
        |> Enum.with_index()
        |> Enum.map(fn {sha, i} -> %{sha: sha, offset: i * 17 + 12, crc: i} end)

      encoded = Index.encode(first_wave, @checksum)
      assert {:ok, index} = Index.decode(encoded)
      fanout = fanout(encoded)
      assert length(fanout) == 256
      assert fanout == Enum.to_list(1..256)
      assert List.last(fanout) == length(first_wave)

      for entry <- first_wave, do: assert(Index.offset(index, entry.sha) == entry.offset)

      # A second wave adds 64 entries to the zero bucket: the index must grow
      # without disturbing earlier lookups.
      second_wave =
        for i <- 0..63 do
          raw = <<0, i>> <> binary_part(:crypto.hash(:sha, <<0, i>>), 0, 18)
          %{sha: Base.encode16(raw, case: :lower), offset: 10_000 + i, crc: 1_000 + i}
        end

      grown = Index.encode(first_wave ++ second_wave, @checksum)
      assert {:ok, grown_index} = Index.decode(grown)
      grown_fanout = fanout(grown)

      assert hd(grown_fanout) == 65
      assert List.last(grown_fanout) == 320
      assert grown_fanout == Enum.sort(grown_fanout)

      for entry <- first_wave ++ second_wave do
        assert Index.offset(grown_index, entry.sha) == entry.offset
      end
    end

    test "64-bit offsets use the large-offset table" do
      [a, b, c] = shas(3)

      entries = [
        %{sha: a, offset: 12, crc: 1},
        %{sha: b, offset: 0x8000_0000, crc: 2},
        %{sha: c, offset: 0x1_0000_0000, crc: 3}
      ]

      assert {:ok, index} = Index.decode(Index.encode(entries, @checksum))
      assert index.offsets[a] == 12
      assert index.offsets[b] == 0x8000_0000
      assert index.offsets[c] == 0x1_0000_0000
    end
  end

  describe "validation" do
    test "rejects a corrupted checksum" do
      encoded = Index.encode([], @checksum)

      # Flip the last byte instead of overwriting it with zero: `@checksum` is
      # random, so a zero byte is a no-op 1 run in 256 and the assertion fails.
      flipped = Bitwise.bxor(:binary.last(encoded), 0xFF)
      corrupted = binary_part(encoded, 0, byte_size(encoded) - 1) <> <<flipped>>

      assert {:error, :invalid_index_checksum} = Index.decode(corrupted)
    end

    test "rejects a bad magic" do
      encoded = Index.encode([], @checksum)
      corrupted = "XXXX" <> binary_part(encoded, 4, byte_size(encoded) - 4)
      assert {:error, :invalid_index_magic} = Index.decode(corrupted)
    end

    test "rejects an unsupported version" do
      assert {:error, :unsupported_index_version} = Index.decode(<<0xFF, "tOc", 3::32>>)
    end

    test "rejects a fanout that disagrees with the SHA list" do
      encoded = Index.encode([], @checksum)
      <<prefix::binary-size(8), first_fanout::32-big, rest::binary>> = encoded
      broken = prefix <> <<first_fanout + 1::32-big>> <> rest
      assert {:error, :invalid_fanout} = Index.decode(resign(broken))
    end

    test "rejects an orphaned large-offset reference" do
      [sha] = shas(1)
      entries = [%{sha: sha, offset: 12, crc: 1}]
      encoded = Index.encode(entries, @checksum)

      # Turn the 32-bit offset word into a large-offset reference with no table.
      <<prefix::binary-size(8 + 1024 + 20 + 4), _offset::32-big, suffix::binary>> = encoded
      broken = prefix <> <<0x8000_0000::32-big>> <> suffix
      assert {:error, :invalid_large_offset} = Index.decode(resign(broken))
    end

    test "rejects duplicate SHAs" do
      [sha] = shas(1)

      entries = [
        %{sha: sha, offset: 12, crc: 1},
        %{sha: sha, offset: 24, crc: 2}
      ]

      assert {:error, :duplicate_shas} = Index.decode(Index.encode(entries, @checksum))
    end

    test "rejects a truncated index" do
      encoded = Index.encode([], @checksum)
      truncated = binary_part(encoded, 0, 100)
      assert {:error, :truncated_index} = Index.decode(truncated)
    end
  end

  test "pack_path/1 pairs an idx with its pack" do
    assert Index.pack_path("/tmp/objects/pack/pack-abc.idx") == "/tmp/objects/pack/pack-abc.pack"
  end

  defp resign(bin) do
    body = binary_part(bin, 0, byte_size(bin) - 20)
    body <> :crypto.hash(:sha, body)
  end

  # Fanout table: 256 big-endian counts after the 8-byte magic/version header.
  defp fanout(<<0xFF, "tOc", 2::32-big, rest::binary>>) do
    for <<count::32-big <- binary_part(rest, 0, 1024)>>, do: count
  end

  defp shas(n) do
    for i <- 0..(n - 1) do
      :crypto.hash(:sha, <<i::32>>) |> Base.encode16(case: :lower)
    end
  end
end
