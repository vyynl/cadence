defmodule Cadence.Shared.GitStore.Pack.DeltaTest do
  use ExUnit.Case, async: true

  alias Cadence.Shared.GitStore.Pack.Delta

  describe "build/2 and apply/2" do
    test "identical content" do
      base = String.duplicate("abcdef", 100)
      assert_round_trip(base, base)
    end

    test "an insertion in the middle" do
      base = "line one\nline two\nline three\n"
      target = "line one\nline two inserted\nline three\n"
      assert_round_trip(base, target)
    end

    test "a deletion" do
      base = "alpha\nbeta\ngamma\ndelta\n"
      target = "alpha\ngamma\ndelta\n"
      assert_round_trip(base, target)
    end

    test "a shared prefix and suffix" do
      base = "header\n" <> String.duplicate("middle\n", 50) <> "footer\n"
      target = "header\n" <> String.duplicate("changed\n", 50) <> "footer\n"
      assert_round_trip(base, target)
    end

    test "an empty base and an empty target" do
      assert_round_trip("", "abc")
      assert_round_trip("abc", "")
      assert_round_trip("", "")
    end

    test "random binary content" do
      :rand.seed(:exsss, {1, 2, 3})
      base = :crypto.strong_rand_bytes(4096)

      target =
        binary_part(base, 0, 1000) <>
          :crypto.strong_rand_bytes(200) <> binary_part(base, 1000, 3096)

      assert_round_trip(base, target)
    end

    test "targets over the delta cap fall back to inserts" do
      base = String.duplicate("x", 10)
      target = String.duplicate("y", 4_194_305)

      assert {:ok, delta} = Delta.build(base, target)
      assert {:ok, ^target} = Delta.apply(base, delta)
    end

    test "a delta can be larger than the target and still be valid" do
      base = "completely different content"
      target = "z"
      assert_round_trip(base, target)
    end
  end

  describe "apply/2 rejects malformed deltas" do
    test "base size mismatch" do
      delta = Delta.encode_varint(99) <> Delta.encode_varint(0)
      assert {:error, :base_size_mismatch} = Delta.apply("abc", delta)
    end

    test "result size mismatch" do
      delta = Delta.encode_varint(3) <> Delta.encode_varint(5) <> <<3, "abc">>
      assert {:error, :result_size_mismatch} = Delta.apply("abc", delta)
    end

    test "a zero command" do
      delta = Delta.encode_varint(3) <> Delta.encode_varint(3) <> <<0>>
      assert {:error, :invalid_command} = Delta.apply("abc", delta)
    end

    test "a copy outside the base" do
      # copy offset 2, size 3 from a 3-byte base
      delta = Delta.encode_varint(3) <> Delta.encode_varint(3) <> <<0x91, 2, 3>>
      assert {:error, :copy_out_of_range} = Delta.apply("abc", delta)
    end

    test "a truncated insert" do
      delta = Delta.encode_varint(0) <> Delta.encode_varint(5) <> <<3, "ab">>
      assert {:error, :truncated_delta} = Delta.apply("", delta)
    end

    test "a truncated varint" do
      assert {:error, :truncated_delta} = Delta.apply("abc", <<0x80>>)
    end

    test "a result larger than the configured cap" do
      delta = Delta.encode_varint(0) <> Delta.encode_varint(1_000_000) <> <<3, "abc">>
      assert {:error, :too_large} = Delta.apply("", delta, max_result_bytes: 100)
    end

    test "an over-long result is rejected before it is built" do
      delta = Delta.encode_varint(0) <> Delta.encode_varint(1) <> <<3, "abc">>
      assert {:error, :result_size_mismatch} = Delta.apply("", delta)
    end
  end

  describe "varint" do
    test "round-trips boundary values" do
      for value <- [0, 1, 127, 128, 255, 16_384, 1_000_000, 4_294_967_295] do
        assert {:ok, ^value, ""} = Delta.decode_varint(Delta.encode_varint(value))
      end
    end
  end

  defp assert_round_trip(base, target) do
    assert {:ok, delta} = Delta.build(base, target)
    assert {:ok, ^target} = Delta.apply(base, delta)
  end
end
