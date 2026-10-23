defmodule Cadence.Shared.Diff do
  @moduledoc """
  Turns `Cadence.Shared.GitStore.diff_trees/3` changes into renderable line
  diffs for the UI (the Neovim hover panel today; the web UI later).

  Line-level diffing uses `List.myers_difference/2` from the standard library,
  so no additional dependency is needed. Unchanged runs longer than the context
  window collapse into a single `:skip` marker (`…`).
  """

  @default_context 3
  @default_max_files 20
  @default_max_lines 400
  @default_max_bytes 262_144

  @type kind :: :ctx | :add | :del | :skip

  @type file :: %{
          path: String.t(),
          status: :added | :modified | :deleted,
          binary: boolean(),
          truncated: boolean(),
          lines: [%{kind: kind(), text: String.t()}]
        }

  @doc """
  Builds per-file line diffs from `GitStore.diff_trees/3` `changes`.

  Options:
    * `:context` — unchanged lines kept around each change (default `3`)
    * `:max_files` — cap on the number of files (default `20`)
    * `:max_lines_per_file` — cap on lines per file (default `400`)
    * `:max_bytes` — skip line diffing for files larger than this (default
      `262_144`), marking them truncated. This bounds CPU/memory before the
      line cap is applied.

  Returns `%{files: [file], truncated: boolean}` where `truncated` indicates a
  file was dropped by `:max_files`.
  """
  @spec files([map()], keyword()) :: %{files: [file()], truncated: boolean()}
  def files(changes, opts \\ []) do
    max_files = Keyword.get(opts, :max_files, @default_max_files)
    {kept, dropped} = Enum.split(changes, max_files)

    %{
      files: Enum.map(kept, &file(&1, opts)),
      truncated: dropped != []
    }
  end

  defp file(change, opts) do
    max_lines = Keyword.get(opts, :max_lines_per_file, @default_max_lines)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    context = Keyword.get(opts, :context, @default_context)

    {binary, lines, oversized} = diff_lines(change, context, max_bytes)

    {lines, line_truncated} =
      if length(lines) > max_lines do
        {Enum.take(lines, max_lines), true}
      else
        {lines, false}
      end

    %{
      path: change.path,
      status: change.status,
      binary: binary,
      truncated: oversized or line_truncated,
      lines: lines
    }
  end

  defp diff_lines(change, context, max_bytes) do
    if oversized?(change, max_bytes) do
      {false, [], true}
    else
      {binary, lines} = diff_lines(change, context)
      {binary, lines, false}
    end
  end

  defp oversized?(%{status: :modified, old_content: old, new_content: new}, max_bytes)
       when is_integer(max_bytes) do
    not binary?(old) and not binary?(new) and
      byte_size(old || "") + byte_size(new || "") > max_bytes
  end

  defp oversized?(%{status: :added, new_content: new}, max_bytes) when is_integer(max_bytes) do
    not binary?(new) and byte_size(new || "") > max_bytes
  end

  defp oversized?(%{status: :deleted, old_content: old}, max_bytes) when is_integer(max_bytes) do
    not binary?(old) and byte_size(old || "") > max_bytes
  end

  defp oversized?(_change, _max_bytes), do: false

  defp diff_lines(%{status: :modified, old_content: old, new_content: new}, context) do
    if binary?(old) or binary?(new) do
      {true, []}
    else
      lines = old |> split_lines() |> myers(split_lines(new)) |> collapse(context)
      {false, lines}
    end
  end

  defp diff_lines(%{status: :added, new_content: new}, _context) do
    if binary?(new), do: {true, []}, else: {false, tag(split_lines(new), :add)}
  end

  defp diff_lines(%{status: :deleted, old_content: old}, _context) do
    if binary?(old), do: {true, []}, else: {false, tag(split_lines(old), :del)}
  end

  defp tag(lines, kind), do: Enum.map(lines, &%{kind: kind, text: &1})

  defp myers(old, new) do
    old
    |> List.myers_difference(new)
    |> Enum.flat_map(fn
      {:eq, lines} -> tag(lines, :ctx)
      {:del, lines} -> tag(lines, :del)
      {:ins, lines} -> tag(lines, :add)
    end)
  end

  # Keep `context` lines around each change; collapse omitted runs into one `…`.
  defp collapse(lines, context) do
    last = length(lines) - 1

    changed =
      for {line, index} <- Enum.with_index(lines), line.kind != :ctx, do: index

    if changed == [] do
      []
    else
      keep =
        changed
        |> Enum.flat_map(fn index -> max(index - context, 0)..min(index + context, last) end)
        |> MapSet.new()

      {result, _skipping} =
        lines
        |> Enum.with_index()
        |> Enum.reduce({[], false}, fn {line, index}, {acc, skipping} ->
          cond do
            MapSet.member?(keep, index) -> {[line | acc], false}
            skipping -> {acc, true}
            true -> {[%{kind: :skip, text: "…"} | acc], true}
          end
        end)

      Enum.reverse(result)
    end
  end

  defp split_lines(text) do
    lines = String.split(text || "", "\n")

    case Enum.reverse(lines) do
      ["" | rest] -> Enum.reverse(rest)
      _ -> lines
    end
  end

  defp binary?(text), do: is_binary(text) and String.contains?(text, <<0>>)
end
