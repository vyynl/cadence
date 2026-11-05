defmodule Cadence.Shared.LLM.Meld do
  @moduledoc """
  Prompt building and strict response parsing for AI-assisted meld conflict
  resolution (spec §6.5, §6.6, §9).

  The prompt template is plain text in
  `cadence_shared/priv/prompts/meld.txt`; this module only substitutes the
  parent summaries and conflicting versions. The parser is line-oriented and
  never raises: model output is untrusted, mapped through a fixed
  string-to-atom table (never `String.to_atom/1`), and every emitted path must
  appear in the caller's conflict allowlist.
  """

  @prompt_version "meld-v1"

  @default_max_context_bytes 65_536
  @default_max_ops 50
  @default_max_file_bytes 262_144

  @operations %{"CREATE" => :create, "MODIFY" => :modify, "DELETE" => :delete}

  @doc "The prompt template version recorded with every meld result."
  @spec prompt_version() :: String.t()
  def prompt_version, do: @prompt_version

  @doc """
  Build the meld prompt.

  `parents` is a list of `%{id, message, flags, files}` maps (the same shape
  `Cadence.Shared.Meld.union/1` accepts) and `conflicts` is the union's
  conflict map (`%{path => [%{id, ref, content}]}`).

  Returns `{:ok, prompt}`, or `{:error, :context_too_large}` when the conflict
  paths cannot all fit the context budget. Omitting a conflicting path would
  make the result impossible to satisfy (`Meld.apply_ops/3` requires every
  conflict resolved), so truncation of the *path set* is an error; individual
  versions may still be truncated within the rendered block.

  Options:

    * `:max_context_bytes` — shared budget for the rendered parent file lists
      and conflict contents (default #{@default_max_context_bytes}).

  Binary conflict content is replaced by a marker; it must never be sent to the
  model as-is.
  """
  @spec build_prompt([map()], %{String.t() => [map()]}, keyword()) ::
          {:ok, String.t()} | {:error, :context_too_large}
  def build_prompt(parents, conflicts, opts \\ []) when is_list(parents) and is_map(conflicts) do
    max_context_bytes = Keyword.get(opts, :max_context_bytes, @default_max_context_bytes)

    with {:ok, conflicts_text} <- render_conflicts(conflicts, max_context_bytes) do
      values = %{
        "parent_count" => Integer.to_string(length(parents)),
        "parents" => render_parents(parents, max_context_bytes),
        "conflicts" => conflicts_text
      }

      {:ok,
       :cadence_shared
       |> Application.app_dir("priv/prompts/meld.txt")
       |> File.read!()
       |> substitute(values)}
    end
  end

  # Single pass so substituted file content can never introduce a placeholder
  # that a later replacement would expand.
  defp substitute(template, values) do
    Regex.replace(~r/\{\{(parent_count|parents|conflicts)\}\}/, template, fn _, key ->
      Map.fetch!(values, key)
    end)
  end

  @doc """
  Parse a model response into file operations.

  Allowed paths come from the union's conflict set; anything else is
  `:unknown_path`. Options:

    * `:max_ops` — maximum number of operations (default #{@default_max_ops})
    * `:max_file_bytes` — maximum content size per operation
      (default #{@default_max_file_bytes})

  Returns `{:ok, ops}` or `{:error, reason}` with one of `:missing_begin`,
  `:missing_end`, `:malformed_op`, `:invalid_operation`, `:unknown_path`,
  `:duplicate_path`, `:missing_content`, `:too_many_ops`, `:file_too_large`.
  """
  @spec parse(String.t(), Enumerable.t(), keyword()) ::
          {:ok,
           [
             {:create, String.t(), binary()}
             | {:modify, String.t(), binary()}
             | {:delete, String.t()}
           ]}
          | {:error,
             :missing_begin
             | :missing_end
             | :malformed_op
             | :invalid_operation
             | :unknown_path
             | :duplicate_path
             | :missing_content
             | :too_many_ops
             | :file_too_large}
  def parse(text, allowed_paths, opts \\ [])

  def parse(text, allowed_paths, opts) when is_binary(text) do
    max_ops = Keyword.get(opts, :max_ops, @default_max_ops)
    max_file_bytes = Keyword.get(opts, :max_file_bytes, @default_max_file_bytes)
    allowed = MapSet.new(allowed_paths)
    lines = String.split(text, "\n")

    with {:ok, begin_index} <- find_marker(lines, "MELD_BEGIN", :missing_begin, 0),
         {:ok, end_index} <- find_marker(lines, "MELD_END", :missing_end, begin_index + 1) do
      lines
      |> Enum.slice((begin_index + 1)..(end_index - 1)//1)
      |> parse_ops(allowed, max_ops, max_file_bytes)
    end
  end

  def parse(_text, _allowed_paths, _opts), do: {:error, :malformed_op}

  ## Prompt rendering

  defp render_parents(parents, budget) do
    {blocks, _remaining} =
      parents
      |> Enum.with_index(1)
      |> Enum.map_reduce(budget, fn {parent, index}, remaining ->
        {block, used} = render_parent(parent, index, remaining)
        {block, max(remaining - min(used, remaining), 0)}
      end)

    Enum.join(blocks, "\n\n")
  end

  defp render_parent(parent, index, budget) do
    paths = parent |> Map.get(:files, %{}) |> Map.keys() |> Enum.sort()
    {listed, taken, omitted} = take_paths(paths, budget)

    file_lines = Enum.map(listed, &"  #{&1}")

    file_lines =
      if omitted > 0, do: file_lines ++ ["  ... (#{omitted} more files)"], else: file_lines

    lines = [
      "Parent #{index} (id: #{parent.id})",
      "Message: #{one_line(Map.get(parent, :message))}",
      "Flags: #{render_flags(Map.get(parent, :flags))}",
      "Files (#{taken + omitted}):" | file_lines
    ]

    {Enum.join(lines, "\n"), byte_size(Enum.join(lines, "\n"))}
  end

  defp take_paths(paths, budget), do: take_paths(paths, budget, [])
  defp take_paths([], _budget, acc), do: {Enum.reverse(acc), length(acc), 0}

  defp take_paths([path | rest], budget, acc) do
    cost = byte_size(path) + 3

    if cost <= budget do
      take_paths(rest, budget - cost, [path | acc])
    else
      {Enum.reverse(acc), length(acc), length([path | rest])}
    end
  end

  defp render_conflicts(conflicts, budget) do
    {blocks, omitted} =
      conflicts
      |> Enum.sort_by(&elem(&1, 0))
      |> collect_conflicts(budget, [])

    if omitted == 0 do
      {:ok, blocks |> Enum.reverse() |> Enum.join("\n\n")}
    else
      {:error, :context_too_large}
    end
  end

  defp collect_conflicts([], _remaining, acc), do: {acc, 0}

  defp collect_conflicts(remaining_conflicts, remaining, acc) when remaining <= 0 do
    {acc, length(remaining_conflicts)}
  end

  defp collect_conflicts([{path, versions} | rest], remaining, acc) do
    {block, used} = render_conflict(path, versions, remaining)
    collect_conflicts(rest, remaining - min(used, remaining), [block | acc])
  end

  defp render_conflict(path, versions, budget) do
    header = "File: #{path}\n"
    per_version = max(div(max(budget - byte_size(header), 0), max(length(versions), 1)), 0)

    blocks = Enum.map(versions, &render_version(&1, per_version))
    block = header <> Enum.join(blocks, "\n")

    {block, byte_size(block)}
  end

  defp render_version(%{id: id, content: content}, budget) do
    if binary_content?(content) do
      "--- parent #{id} ---\n(binary content omitted)"
    else
      "--- parent #{id} ---\n" <> truncate(content, budget)
    end
  end

  defp binary_content?(content) when is_binary(content) do
    not String.valid?(content) or :binary.match(content, <<0>>) != :nomatch
  end

  defp binary_content?(_content), do: true

  defp truncate(content, budget) when byte_size(content) <= budget, do: content
  defp truncate(_content, budget) when budget <= 0, do: "(content omitted for length)"

  defp truncate(content, budget) do
    prefix = binary_part(content, 0, budget)

    prefix =
      if String.valid?(prefix) do
        prefix
      else
        prefix |> trim_invalid_tail(byte_size(prefix) - 1, 3)
      end

    prefix <> "\n... (truncated)"
  end

  defp trim_invalid_tail(_prefix, _index, 0), do: ""
  defp trim_invalid_tail(_prefix, index, _attempts) when index <= 0, do: ""

  defp trim_invalid_tail(prefix, index, attempts) when index > 0 do
    candidate = binary_part(prefix, 0, index)

    if String.valid?(candidate) do
      candidate
    else
      trim_invalid_tail(prefix, index - 1, attempts - 1)
    end
  end

  defp one_line(nil), do: "(none)"
  defp one_line(message) when is_binary(message), do: message |> String.split("\n") |> hd()

  defp render_flags(nil), do: "(none)"
  defp render_flags([]), do: "(none)"
  defp render_flags(flags) when is_list(flags), do: Enum.join(flags, ", ")

  ## Response parsing

  defp find_marker(lines, marker, error, from) do
    lines
    |> Enum.drop(from)
    |> Enum.find_index(&(String.trim(&1) == marker))
    |> case do
      nil -> {:error, error}
      index -> {:ok, index + from}
    end
  end

  defp parse_ops(lines, allowed, max_ops, max_file_bytes) do
    lines
    |> Enum.drop_while(&blank?/1)
    |> do_parse(allowed, max_ops, max_file_bytes, [], MapSet.new())
  end

  defp do_parse([], _allowed, _max_ops, _max_file_bytes, ops, _seen),
    do: {:ok, Enum.reverse(ops)}

  defp do_parse([line | rest], allowed, max_ops, max_file_bytes, ops, seen) do
    with {:ok, kind, path} <- parse_header(line),
         :ok <- check_allowed(path, allowed),
         :ok <- check_duplicate(path, seen),
         :ok <- check_count(length(ops), max_ops) do
      seen = MapSet.put(seen, path)

      case kind do
        :delete ->
          rest
          |> Enum.drop_while(&blank?/1)
          |> do_parse(allowed, max_ops, max_file_bytes, [{:delete, path} | ops], seen)

        kind ->
          with {:ok, content, remaining} <- take_content(rest, max_file_bytes) do
            do_parse(
              remaining,
              allowed,
              max_ops,
              max_file_bytes,
              [{kind, path, content} | ops],
              seen
            )
          end
      end
    end
  end

  defp parse_header(line) do
    case line |> String.trim() |> String.split(" ", parts: 3) do
      ["FILE", operation, path] ->
        path = String.trim(path)

        case Map.fetch(@operations, operation) do
          {:ok, kind} when path != "" -> {:ok, kind, path}
          {:ok, _kind} -> {:error, :malformed_op}
          :error -> {:error, :invalid_operation}
        end

      _other ->
        {:error, :malformed_op}
    end
  end

  defp check_allowed(path, allowed) do
    if MapSet.member?(allowed, path), do: :ok, else: {:error, :unknown_path}
  end

  defp check_duplicate(path, seen) do
    if MapSet.member?(seen, path), do: {:error, :duplicate_path}, else: :ok
  end

  defp check_count(current, max_ops) do
    if current + 1 > max_ops, do: {:error, :too_many_ops}, else: :ok
  end

  defp take_content(lines, max_file_bytes) do
    case Enum.drop_while(lines, &blank?/1) do
      [opening | body] ->
        if String.trim(opening) == "<<<" do
          split_content(body, max_file_bytes, [])
        else
          {:error, :missing_content}
        end

      [] ->
        {:error, :missing_content}
    end
  end

  defp split_content([], _max_file_bytes, _acc), do: {:error, :missing_content}

  defp split_content([line | rest], max_file_bytes, acc) do
    if String.trim(line) == ">>>" do
      content = acc |> Enum.reverse() |> Enum.join("\n")

      if byte_size(content) > max_file_bytes do
        {:error, :file_too_large}
      else
        {:ok, content, rest}
      end
    else
      split_content(rest, max_file_bytes, [line | acc])
    end
  end

  defp blank?(line), do: String.trim(line) == ""
end
