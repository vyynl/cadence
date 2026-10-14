defmodule Cadence.Shared.SyncTest do
  use ExUnit.Case, async: true

  alias Cadence.Shared.Sync.{
    PushNodes,
    PushNodesResponse,
    PullNodes,
    PullNodesResponse,
    PushPreferences,
    Union,
    UnionResponse
  }

  describe "PushNodes" do
    test "encodes nodes to JSON" do
      msg = %PushNodes{nodes: [%{local_id: "l1", git_objects: [], metadata: %{}}]}

      assert decode(msg) == %{
               "nodes" => [%{"local_id" => "l1", "git_objects" => [], "metadata" => %{}}]
             }
    end
  end

  describe "PushNodesResponse" do
    test "carries local_id → cloud_id mappings" do
      msg = %PushNodesResponse{mappings: [%{local_id: "l1", cloud_id: "c1"}]}

      assert decode(msg) == %{"mappings" => [%{"local_id" => "l1", "cloud_id" => "c1"}]}
    end
  end

  describe "PullNodes" do
    test "has a nil cursor by default" do
      assert %PullNodes{since: nil} = %PullNodes{since: nil}
    end
  end

  describe "PullNodesResponse" do
    test "carries nodes and a cursor" do
      msg = %PullNodesResponse{nodes: [%{id: "n1"}], cursor: "abc"}

      assert decode(msg) == %{"nodes" => [%{"id" => "n1"}], "cursor" => "abc"}
    end
  end

  describe "PushPreferences" do
    test "carries active_heads and session_pointer" do
      msg = %PushPreferences{project_id: "p1", active_heads: ["n1"], session_pointer: "n1"}

      assert decode(msg) == %{
               "project_id" => "p1",
               "active_heads" => ["n1"],
               "session_pointer" => "n1"
             }
    end
  end

  describe "Union" do
    test "carries project_id and parent_node_ids" do
      msg = %Union{project_id: "p1", parent_node_ids: ["n1", "n2"]}

      assert decode(msg) == %{"project_id" => "p1", "parent_node_ids" => ["n1", "n2"]}
    end
  end

  describe "UnionResponse" do
    test "carries the meld node id" do
      assert decode(%UnionResponse{meld_node_id: "m1"}) == %{"meld_node_id" => "m1"}
    end
  end

  defp decode(struct), do: Jason.decode!(Jason.encode!(struct))
end
