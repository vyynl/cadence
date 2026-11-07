defmodule Cadence.Shared.GitStore.PackTest do
  use ExUnit.Case, async: true

  alias Cadence.Shared.GitStore.Pack
  alias Cadence.Shared.GitStore.Pack.{Delta, Index}

  setup do
    dir = Path.join(System.tmp_dir!(), "cadence_pack_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  describe "known-byte pack" do
    test "reads a hand-built single-blob pack", %{dir: dir} do
      data = "hello world\n"

      entry = Pack.entry_header(:blob, byte_size(data)) <> :zlib.compress(data)
      body = "PACK" <> <<2::32>> <> <<1::32>> <> entry
      pack = body <> :crypto.hash(:sha, body)

      sha = git_sha(:blob, data)
      idx = index([%{sha: sha, offset: 12, crc: :erlang.crc32(entry)}], sha1(body))

      path = Path.join(dir, "hand.pack")
      File.write!(path, pack)

      assert Pack.entry_header(:blob, 12) == <<0x3C>>
      assert {:ok, {:blob, ^data}} = Pack.read_object(path, idx.offsets, sha)
    end

    test "ofs-delta distances use Git's decrementing varint" do
      assert Pack.ofs_delta_offset(1) == <<1>>
      assert Pack.ofs_delta_offset(127) == <<127>>
      assert Pack.ofs_delta_offset(128) == <<0x80, 0>>
      assert Pack.ofs_delta_offset(16_384) == <<0xFF, 0>>
    end
  end

  describe "encode/2" do
    test "round-trips commit, tree, and blob entries", %{dir: dir} do
      objects = [
        object(:commit, "tree deadbeef\n"),
        object(:tree, "100644 a.txt\0deadbeef"),
        object(:blob, "hello\n")
      ]

      {path, offsets, _encoded} = write_pack(dir, objects)

      for %{sha: sha, type: type, data: data} <- objects do
        assert {:ok, {^type, ^data}} = Pack.read_object(path, offsets, sha)
      end
    end

    test "chooses a delta for similar blobs", %{dir: dir} do
      base = Enum.map_join(1..300, fn i -> "line #{i} of text #{:erlang.phash2(i)}\n" end)
      target = String.replace(base, "line 150 of", "one changed line 150 of")
      objects = [object(:blob, base), object(:blob, target)]

      {path, offsets, encoded} = write_pack(dir, objects)

      assert Enum.any?(encoded.entries, &(&1.stored_type == :ofs_delta))
      assert {:ok, {:blob, ^base}} = Pack.read_object(path, offsets, hd(objects).sha)
      assert {:ok, {:blob, ^target}} = Pack.read_object(path, offsets, List.last(objects).sha)
    end

    test "a chain of deltas resolves", %{dir: dir} do
      blobs =
        for i <- 1..4 do
          object(
            :blob,
            Enum.map_join(1..200, fn j -> "shared #{j} line #{:erlang.phash2(j)}\n" end) <>
              "revision #{i}\n"
          )
        end

      {path, offsets, encoded} = write_pack(dir, blobs)

      assert Enum.count(encoded.entries, &(&1.stored_type == :ofs_delta)) >= 2

      for %{sha: sha, data: data} <- blobs do
        assert {:ok, {:blob, ^data}} = Pack.read_object(path, offsets, sha)
      end
    end

    test "respects the delta depth cap", %{dir: dir} do
      blobs =
        for i <- 1..4 do
          object(
            :blob,
            Enum.map_join(1..200, fn j -> "shared #{j} line #{:erlang.phash2(j)}\n" end) <>
              "revision #{i}\n"
          )
        end

      {path, offsets, _encoded} = write_pack(dir, blobs)
      last = List.last(blobs)

      assert {:error, :delta_chain_too_deep} =
               Pack.read_object(path, offsets, last.sha, max_depth: 0)
    end

    test "bounds delta chains to the reader depth cap", %{dir: dir} do
      blobs =
        for i <- 1..60 do
          object(
            :blob,
            Enum.map_join(1..100, fn j -> "segment #{j} #{:erlang.phash2(j)}\n" end) <>
              "revision #{i}\n"
          )
        end

      {path, offsets, encoded} = write_pack(dir, blobs)

      # At least one full entry breaks the chain before the depth cap.
      assert Enum.any?(encoded.entries, &(&1.stored_type == :blob))

      for %{sha: sha, data: data} <- blobs do
        assert {:ok, {:blob, ^data}} = Pack.read_object(path, offsets, sha)
      end
    end

    test "an empty pack is a valid header and trailer" do
      assert {:ok, encoded} = Pack.encode([])
      assert binary_part(encoded.pack, 0, 4) == "PACK"
      assert byte_size(encoded.pack) == 12 + 20
      assert encoded.entries == []
    end
  end

  describe "ref-delta" do
    test "resolves a base referenced by SHA", %{dir: dir} do
      base = String.duplicate("ref base line\n", 100)
      target = String.replace(base, "ref base line\n", "ref target line\n", global: false)

      {:ok, delta} = Delta.build(base, target)
      base_sha = git_sha(:blob, base)
      target_sha = git_sha(:blob, target)

      base_entry = Pack.entry_header(:blob, byte_size(base)) <> :zlib.compress(base)

      delta_entry =
        Pack.entry_header(7, byte_size(delta)) <>
          Base.decode16!(base_sha, case: :lower) <> :zlib.compress(delta)

      body = "PACK" <> <<2::32>> <> <<2::32>> <> base_entry <> delta_entry
      pack = body <> sha1(body)

      entries = [
        %{sha: base_sha, offset: 12, crc: :erlang.crc32(base_entry)},
        %{
          sha: target_sha,
          offset: 12 + byte_size(base_entry),
          crc: :erlang.crc32(delta_entry)
        }
      ]

      idx = index(entries, sha1(body))
      path = Path.join(dir, "ref.pack")
      File.write!(path, pack)

      assert {:ok, {:blob, ^target}} = Pack.read_object(path, idx.offsets, target_sha)
    end
  end

  describe "malformed packs" do
    test "a missing SHA", %{dir: dir} do
      {path, offsets, _encoded} = write_pack(dir, [object(:blob, "hello\n")])

      assert {:error, :not_found} =
               Pack.read_object(path, offsets, String.duplicate("0", 40))
    end

    test "a truncated pack", %{dir: dir} do
      {path, offsets, encoded} = write_pack(dir, [object(:blob, String.duplicate("x", 5000))])
      File.write!(path, binary_part(encoded.pack, 0, 20))

      [sha] = Map.keys(offsets)
      assert {:error, _reason} = Pack.read_object(path, offsets, sha)
    end

    test "a payload that is not zlib", %{dir: dir} do
      data = "hello\n"
      sha = git_sha(:blob, data)
      entry = Pack.entry_header(:blob, byte_size(data)) <> "not zlib"
      body = "PACK" <> <<2::32>> <> <<1::32>> <> entry
      pack = body <> sha1(body)

      idx = index([%{sha: sha, offset: 12, crc: :erlang.crc32(entry)}], sha1(body))
      path = Path.join(dir, "bad.pack")
      File.write!(path, pack)

      assert {:error, :invalid_zlib} = Pack.read_object(path, idx.offsets, sha)
    end

    test "an unknown entry type", %{dir: dir} do
      data = "hello\n"
      sha = git_sha(:blob, data)
      entry = Pack.entry_header(5, byte_size(data)) <> :zlib.compress(data)
      body = "PACK" <> <<2::32>> <> <<1::32>> <> entry
      pack = body <> sha1(body)

      idx = index([%{sha: sha, offset: 12, crc: :erlang.crc32(entry)}], sha1(body))
      path = Path.join(dir, "unknown.pack")
      File.write!(path, pack)

      assert {:error, :unsupported_type} = Pack.read_object(path, idx.offsets, sha)
    end
  end

  defp write_pack(dir, objects) do
    {:ok, encoded} = Pack.encode(objects)
    idx = index(encoded.entries, encoded.checksum)
    path = Path.join(dir, "test-#{System.unique_integer([:positive])}.pack")
    File.write!(path, encoded.pack)
    {path, idx.offsets, encoded}
  end

  defp index(entries, pack_checksum) do
    entries
    |> Index.encode(pack_checksum)
    |> Index.decode()
    |> elem(1)
  end

  defp object(type, data) do
    %{sha: git_sha(type, data), type: type, data: data}
  end

  defp git_sha(type, data) do
    :crypto.hash(:sha, [
      Atom.to_string(type),
      " ",
      Integer.to_string(byte_size(data)),
      <<0>>,
      data
    ])
    |> Base.encode16(case: :lower)
  end

  defp sha1(data), do: :crypto.hash(:sha, data)
end
