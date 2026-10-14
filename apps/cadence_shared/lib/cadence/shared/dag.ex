defmodule Cadence.Shared.DAG do
  @moduledoc """
  Structural queries over a project's DAG of `Cadence.Shared.Node`s.

  These are renderer-agnostic graph facts — edges, topological depth, roots,
  and the selection of a "default" or "preview" node. The Neovim picker (and,
  later, the web UI) turns this structure into coordinates and glyphs; the
  layout/pixel concerns stay in each renderer.

  Functions accept either `%Cadence.Shared.Node{}` structs or plain maps with
  the same keys (`:id`, `:parents`, `:flags`, `:pinned`, `:created_at`,
  `:created_by`), which keeps them easy to unit test.
  """

  alias Cadence.Shared.Node

  @type dag_node :: Node.t() | map()
  @type id :: String.t()

  @doc """
  Builds a directed `Graph` of the nodes: vertices are node ids and each edge
  points from a parent to its child.
  """
  @spec graph([dag_node()]) :: Graph.t()
  def graph(nodes) do
    base = Enum.reduce(nodes, Graph.new(type: :directed), &Graph.add_vertex(&2, &1.id))

    Enum.reduce(nodes, base, fn node, acc ->
      Enum.reduce(node.parents || [], acc, fn parent_id, inner ->
        Graph.add_edge(inner, parent_id, node.id)
      end)
    end)
  end

  @doc """
  Maps each node id to its topological depth: the longest path from any root.
  A root has depth 0; a meld (2+ parents) is one below its deepest parent.

  Returns `%{}` for an empty list. Raises if the graph contains a cycle (which
  should never happen for a node DAG).
  """
  @spec depths([dag_node()]) :: %{id() => non_neg_integer()}
  def depths(nodes) do
    graph = graph(nodes)

    case Graph.topsort(graph) do
      false ->
        raise ArgumentError, "cycle detected in node graph"

      order ->
        Enum.reduce(order, %{}, fn id, acc ->
          Map.put(acc, id, depth_of(graph, id, acc))
        end)
    end
  end

  @doc "Returns the parent→child edges as `%{from: parent_id, to: child_id}` maps."
  @spec edges([dag_node()]) :: [%{from: id(), to: id()}]
  def edges(nodes) do
    Enum.flat_map(nodes, fn node ->
      Enum.map(node.parents || [], &%{from: &1, to: node.id})
    end)
  end

  @doc "Returns the ids of nodes with no parents."
  @spec roots([dag_node()]) :: [id()]
  def roots(nodes) do
    for node <- nodes, (node.parents || []) == [], do: node.id
  end

  @doc "Returns `%{parent_id => [child_id]}`."
  @spec children([dag_node()]) :: %{id() => [id()]}
  def children(nodes) do
    Enum.reduce(nodes, %{}, fn node, acc ->
      Enum.reduce(node.parents || [], acc, fn parent_id, inner ->
        Map.update(inner, parent_id, [node.id], &[node.id | &1])
      end)
    end)
  end

  @doc """
  Resolves the preview node (spec §4.4), or `nil` for an empty project:

  pinned (newest) → `functioning` (newest) → newest overall.
  """
  @spec preview_node([dag_node()]) :: dag_node() | nil
  def preview_node([]), do: nil

  def preview_node(nodes) do
    sorted = sort_recent(nodes)

    Enum.find(sorted, &pinned?/1) ||
      Enum.find(sorted, &functioning?/1) ||
      List.first(sorted)
  end

  @doc """
  Resolves which node a user's session should anchor on (spec §6.3):

  1. `:session_pointer`, if it matches a node;
  2. the most recent node created by `:user_id`;
  3. the preview node.
  """
  @spec default_node([dag_node()], keyword()) :: dag_node() | nil
  def default_node(nodes, opts \\ []) do
    find_by_id(nodes, opts[:session_pointer]) ||
      most_recent_by_user(nodes, opts[:user_id]) ||
      preview_node(nodes)
  end

  @doc "Returns the most recent node created by `user_id`, or `nil`."
  @spec most_recent_by_user([dag_node()], id() | nil) :: dag_node() | nil
  def most_recent_by_user(_nodes, nil), do: nil

  def most_recent_by_user(nodes, user_id) do
    nodes
    |> Enum.filter(&(&1.created_by == user_id))
    |> sort_recent()
    |> List.first()
  end

  defp find_by_id(_nodes, nil), do: nil
  defp find_by_id(nodes, id), do: Enum.find(nodes, &(&1.id == id))

  defp depth_of(graph, id, acc) do
    case Graph.in_neighbors(graph, id) do
      [] -> 0
      parents -> parents |> Enum.map(&Map.get(acc, &1, 0)) |> Enum.max() |> Kernel.+(1)
    end
  end

  # Newest first, deterministically broken by id descending.
  defp sort_recent(nodes) do
    Enum.sort(nodes, fn a, b ->
      case DateTime.compare(a.created_at, b.created_at) do
        :gt -> true
        :lt -> false
        :eq -> a.id >= b.id
      end
    end)
  end

  defp pinned?(node), do: node.pinned == true
  defp functioning?(node), do: :functioning in (node.flags || [])
end
