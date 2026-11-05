defmodule Cadence.Shared.Meld do
  @moduledoc """
  Deterministic union of parent session trees and validation of the model's
  conflict resolutions (spec §6.5, §6.6).

  A meld is *not* "ask the AI to merge everything": non-conflicting paths are
  computed here from blob SHAs alone, and only paths on which parents disagree
  reach the model. The model returns file operations, which `apply_ops/3`
  validates against the conflict set before any object is written.

  Nothing in this module creates a node or chooses a flag; `intended_flag/0`
  is the single flag a meld may carry. `functioning` is intentionally not
  representable.

  Pure: no I/O, no configuration reads. Caps are passed by callers so the
  daemon and server can use different limits.
  """

  @type file :: %{ref: String.t(), content: binary()}
  @type version :: %{id: String.t(), ref: String.t(), content: binary()}
  @type parent :: %{
          required(:id) => String.t(),
          optional(:message) => String.t() | nil,
          optional(:flags) => [atom()],
          required(:files) => %{String.t() => file()}
        }
  @type union :: %{
          agreed: %{String.t() => file()},
          conflicts: %{String.t() => [version()]}
        }
  @type op ::
          {:create, String.t(), binary()}
          | {:modify, String.t(), binary()}
          | {:delete, String.t()}

  @default_max_ops 50
  @default_max_file_bytes 262_144

  @doc """
  The only flag a meld result may carry (spec §3.1).

  `functioning` is validator-owned and deliberately unreachable from this
  module.
  """
  @spec intended_flag() :: :"in-progress"
  def intended_flag, do: :"in-progress"

  @doc """
  Compute the deterministic union of `parents`.

  Each parent is `%{id, message, flags, files: %{path => %{ref, content}}}`.

  A path is **agreed** when every parent that contains it agrees on the blob
  `ref`; it is **conflicting** when parents carry different refs. A path
  present in some parents and absent from others is agreed (presence versus
  absence is not a conflict), and a path absent everywhere does not appear.

  Returns `%{agreed: %{path => %{ref, content}}, conflicts: %{path => versions}}`
  where conflict paths are sorted and each version list keeps the caller's
  parent order.
  """
  @spec union([parent()]) :: union()
  def union(parents) when is_list(parents) do
    parents
    |> versions_by_path()
    |> Enum.reduce({%{}, %{}}, &classify_path/2)
    |> then(fn {agreed, conflicts} ->
      %{agreed: agreed, conflicts: sort_conflicts(conflicts)}
    end)
  end

  @doc """
  Apply model operations to a union and return the result `%{path => content}`.

  Operations are `{:create, path, content}`, `{:modify, path, content}`, and
  `{:delete, path}`. They may only target conflict paths, and every conflict
  must be resolved exactly once; agreed paths are never touched.

  Options:

    * `:max_ops` — maximum number of operations (default #{@default_max_ops})
    * `:max_file_bytes` — maximum content size per create/modify
      (default #{@default_max_file_bytes})

  Errors: `:unknown_path`, `:duplicate_op`, `:unsafe_path`,
  `:unresolved_conflict`, `:too_many_ops`, `:file_too_large`, or
  `:invalid_operation` for a malformed operation tuple.
  """
  @spec apply_ops(union(), [op()], keyword()) ::
          {:ok, %{String.t() => binary()}}
          | {:error,
             :unknown_path
             | :duplicate_op
             | :unsafe_path
             | :unresolved_conflict
             | :too_many_ops
             | :file_too_large
             | :invalid_operation}
  def apply_ops(%{agreed: agreed, conflicts: conflicts}, ops, opts \\ []) when is_list(ops) do
    max_ops = Keyword.get(opts, :max_ops, @default_max_ops)
    max_file_bytes = Keyword.get(opts, :max_file_bytes, @default_max_file_bytes)

    with :ok <- check_op_count(ops, max_ops),
         {:ok, resolved} <- validate_ops(ops, conflicts, max_file_bytes),
         :ok <- check_unresolved(conflicts, resolved) do
      {:ok, materialize(agreed, resolved)}
    end
  end

  ## Union

  defp versions_by_path(parents) do
    Enum.flat_map(parents, fn parent ->
      Enum.map(parent.files, fn {path, %{ref: ref, content: content}} ->
        {path, %{id: parent.id, ref: ref, content: content}}
      end)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp classify_path({path, [first | _] = versions}, {agreed, conflicts}) do
    if versions |> Enum.map(& &1.ref) |> Enum.uniq() |> length() == 1 do
      {Map.put(agreed, path, %{ref: first.ref, content: first.content}), conflicts}
    else
      {agreed, Map.put(conflicts, path, versions)}
    end
  end

  defp sort_conflicts(conflicts) do
    conflicts
    |> Enum.sort_by(&elem(&1, 0))
    |> Map.new()
  end

  ## Op validation

  defp check_op_count(ops, max_ops) when length(ops) <= max_ops, do: :ok
  defp check_op_count(_ops, _max_ops), do: {:error, :too_many_ops}

  defp validate_ops(ops, conflicts, max_file_bytes) do
    ops
    |> Enum.reduce_while({:ok, %{}}, fn op, {:ok, resolved} ->
      case validate_op(op, conflicts, max_file_bytes) do
        {:ok, path, content} ->
          if Map.has_key?(resolved, path) do
            {:halt, {:error, :duplicate_op}}
          else
            {:cont, {:ok, Map.put(resolved, path, content)}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_op({kind, path, content}, conflicts, max_file_bytes)
       when kind in [:create, :modify] and is_binary(content) do
    with :ok <- safe_path(path),
         :ok <- known_conflict(path, conflicts),
         :ok <- check_file_size(content, max_file_bytes) do
      {:ok, path, {:keep, content}}
    end
  end

  defp validate_op({:delete, path}, conflicts, _max_file_bytes) do
    with :ok <- safe_path(path),
         :ok <- known_conflict(path, conflicts) do
      {:ok, path, :delete}
    end
  end

  defp validate_op(_op, _conflicts, _max_file_bytes), do: {:error, :invalid_operation}

  defp safe_path(path) do
    if safe_path?(path), do: :ok, else: {:error, :unsafe_path}
  end

  defp safe_path?(path) when is_binary(path) do
    segments = String.split(path, "/")

    segments != [] and
      Enum.all?(segments, fn segment ->
        segment not in ["", ".", ".."] and
          not String.contains?(segment, ["/", "\\"]) and
          Path.type(segment) != :absolute
      end)
  end

  defp safe_path?(_path), do: false

  defp known_conflict(path, conflicts) do
    if Map.has_key?(conflicts, path), do: :ok, else: {:error, :unknown_path}
  end

  defp check_file_size(content, max_file_bytes) when byte_size(content) <= max_file_bytes,
    do: :ok

  defp check_file_size(_content, _max_file_bytes), do: {:error, :file_too_large}

  defp check_unresolved(conflicts, resolved) do
    if Enum.all?(Map.keys(conflicts), &Map.has_key?(resolved, &1)) do
      :ok
    else
      {:error, :unresolved_conflict}
    end
  end

  ## Result materialization

  defp materialize(agreed, resolved) do
    base = Map.new(agreed, fn {path, %{content: content}} -> {path, content} end)

    Enum.reduce(resolved, base, fn
      {path, {:keep, content}}, acc -> Map.put(acc, path, content)
      {path, :delete}, acc -> Map.delete(acc, path)
    end)
  end
end
