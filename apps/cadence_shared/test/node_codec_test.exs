defmodule Cadence.Shared.Sync.NodeCodecTest do
  use ExUnit.Case, async: true

  alias Cadence.Shared.Node
  alias Cadence.Shared.Sync.NodeCodec

  @sha String.duplicate("a", 40)

  defp sample_node do
    %Node{
      id: Ecto.UUID.generate(),
      project_id: Ecto.UUID.generate(),
      git_commit_sha: @sha,
      parents: [Ecto.UUID.generate()],
      flags: [:"in-progress"],
      pinned: false,
      message: "commit",
      session_metadata: %{"model" => "test"},
      created_by: Ecto.UUID.generate(),
      created_at: ~U[2026-10-23 12:00:00.000000Z],
      docs_state: :pending
    }
  end

  test "encodes and decodes a node with Git objects" do
    node = sample_node()
    objects = [%{sha: @sha, type: :blob, data: "hello"}]

    encoded = NodeCodec.encode_node(node, objects)

    assert encoded["id"] == node.id
    assert encoded["flags"] == ["in-progress"]
    assert encoded["docs_state"] == "pending"
    assert encoded["created_at"] == "2026-10-23T12:00:00.000000Z"
    assert hd(encoded["git_objects"])["type"] == "blob"
    assert Base.decode64!(hd(encoded["git_objects"])["data"]) == "hello"

    assert {:ok, %{attrs: attrs, objects: [object]}} = NodeCodec.decode_node(encoded)
    assert attrs.flags == [:"in-progress"]
    assert attrs.docs_state == :pending
    assert attrs.created_at == node.created_at
    assert attrs.parents == node.parents
    assert object == %{sha: @sha, type: :blob, data: "hello"}
  end

  test "flag and docs-state codecs round-trip" do
    flags = [:"in-progress", :broken, :sandbox, :functioning]
    assert NodeCodec.decode_flags(NodeCodec.encode_flags(flags)) == {:ok, flags}

    for state <- Node.docs_states() do
      assert NodeCodec.decode_docs_state(NodeCodec.encode_docs_state(state)) == {:ok, state}
    end
  end

  test "rejects invalid flags, docs states, timestamps, and objects" do
    assert NodeCodec.decode_flags(["nope"]) == {:error, :invalid_flag}
    assert NodeCodec.decode_flags(:nope) == {:error, :invalid_flag}
    assert NodeCodec.decode_docs_state("nope") == {:error, :invalid_docs_state}
    assert NodeCodec.decode_docs_state(nil) == {:error, :invalid_docs_state}
    assert NodeCodec.decode_datetime("nope") == {:error, :invalid_created_at}

    assert NodeCodec.decode_objects([%{"sha" => @sha, "type" => "blob", "data" => "!!!"}]) ==
             {:error, :invalid_objects}

    assert NodeCodec.decode_objects([%{"sha" => @sha, "type" => "wat", "data" => "aGk="}]) ==
             {:error, :invalid_objects}
  end

  test "rejects malformed node maps" do
    assert {:error, :invalid_node} = NodeCodec.decode_node(%{})
  end
end
