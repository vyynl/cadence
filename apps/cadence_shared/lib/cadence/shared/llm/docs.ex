defmodule Cadence.Shared.LLM.Docs do
  @moduledoc """
  Prompt building and strict response parsing for documentation automation
  (spec §9.3).

  The prompt template is plain text in `cadence_shared/priv/prompts/docs.txt`.
  The parser is line-oriented and never raises: model output is untrusted, every
  path must be allowed by the schema, and content is bounded by options.

  The docs context is rendered with the index file first and always in full —
  truncating it would make required-section validation meaningless. Other doc
  files may be truncated or omitted (the agent only rewrites files it names, so
  an omitted file is simply untouched); the renderer reports omissions.
  """

  alias Cadence.Shared.Docs.Schema
  alias Cadence.Shared.UTF8

  @prompt_version "docs-v1"

  @default_max_context_bytes 65_536
  @default_max_ops 20
  @default_max_file_bytes 262_144

  @operations %{"CREATE" => :create, "MODIFY" => :modify}

  @truncated_marker "\n... (truncated)"
  @truncated_doc_marker "\n... (truncated; do not modify)"
  @binary_marker "(binary content omitted)"

  @doc "The prompt template version recorded with every doc result."
  @spec prompt_version() :: String.t()
  def prompt_version, do: @prompt_version

  @doc """
  Builds the doc-agent prompt.

  Options:

    * `:max_context_bytes` — budget for the rendered schema + current docs
      (default #{@default_max_context_bytes})
    * `:max_doc_bytes` — optional cap on the docs portion alone
    * `:max_diff_bytes` — cap on the rendered diff

  Returns `{:ok, prompt, meta}` or `{:error, :context_too_large}`. `meta` carries
  `:writable_paths` (docs rendered in full) and `:read_only_paths` (docs omitted
  or truncated). Callers must pass `:read_only_paths` to `parse/3` so the model
  cannot overwrite content it never saw.

  Never silently drops a required schema section; the index file is always
  rendered in full or the prompt fails.
  """
  @spec build_prompt(Schema.t(), %{String.t() => binary()}, binary(), keyword()) ::
          {:ok, String.t(), %{writable_paths: [String.t()], read_only_paths: [String.t()]}}
          | {:error, :context_too_large}
  def build_prompt(%Schema{} = schema, docs, diff, opts \\ [])
      when is_map(docs) and is_binary(diff) do
    max_context_bytes = Keyword.get(opts, :max_context_bytes, @default_max_context_bytes)
    max_diff_bytes = Keyword.get(opts, :max_diff_bytes, 32_768)
    max_doc_bytes = Keyword.get(opts, :max_doc_bytes)

    schema_text = render_schema(schema)

    docs_budget =
      max_context_bytes
      |> Kernel.-(byte_size(schema_text))
      |> maybe_cap(max_doc_bytes)

    with true <- byte_size(schema_text) <= max_context_bytes,
         {:ok, docs_text, writable, read_only} <-
           render_docs(docs, schema.index_file, docs_budget) do
      values = %{
        "schema" => schema_text,
        "docs" => docs_text,
        "diff" => render_diff(diff, max_diff_bytes)
      }

      prompt =
        :cadence_shared
        |> Application.app_dir("priv/prompts/docs.txt")
        |> File.read!()
        |> substitute(values)

      {:ok, prompt, %{writable_paths: writable, read_only_paths: read_only}}
    else
      false -> {:error, :context_too_large}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Parses a model response into documentation operations.

  `allowed` is either a `%Schema{}` or an exact list of paths.

  Returns `{:ok, ops}` or `{:error, reason}` with one of `:missing_begin`,
  `:missing_end`, `:malformed_op`, `:invalid_operation`, `:unknown_path`,
  `:read_only_path`, `:duplicate_path`, `:missing_content`, `:too_many_ops`,
  `:file_too_large`.

  Options:

    * `:max_ops` — maximum number of operations (default #{@default_max_ops})
    * `:max_file_bytes` — maximum content size per operation
      (default #{@default_max_file_bytes})
    * `:read_only_paths` — paths the model must not write (docs omitted or
      truncated by `build_prompt/4`)
  """
  @spec parse(String.t(), Schema.t() | [String.t()], keyword()) ::
          {:ok, [{:create | :modify, String.t(), binary()}]}
          | {:error,
             :missing_begin
             | :missing_end
             | :malformed_op
             | :invalid_operation
             | :unknown_path
             | :read_only_path
             | :duplicate_path
             | :missing_content
             | :too_many_ops
             | :file_too_large}
  def parse(text, allowed, opts \\ [])

  def parse(text, %Schema{} = schema, opts) when is_binary(text) do
    do_parse(text, &Schema.allowed_path?(schema, &1), opts)
  end

  def parse(text, allowed, opts) when is_binary(text) and is_list(allowed) do
    set = MapSet.new(allowed)
    do_parse(text, &MapSet.member?(set, &1), opts)
  end

  def parse(_text, _allowed, _opts), do: {:error, :malformed_op}

  @doc """
  Verifies that every `required: true` schema section has a Markdown heading in
  the index file. `max_words` is advisory (recorded, not enforced).

  Returns `:ok` or `{:error, {:missing_sections, [name]}}`.
  """
  @spec validate_required(Schema.t(), %{String.t() => binary()}) ::
          :ok | {:error, {:missing_sections, [String.t()]}}
  def validate_required(%Schema{} = schema, files) when is_map(files) do
    index = Map.get(files, schema.index_file, "")

    missing =
      schema.sections
      |> Enum.filter(& &1.required)
      |> Enum.map(& &1.name)
      |> Enum.reject(&heading?(index, &1))

    if missing == [], do: :ok, else: {:error, {:missing_sections, missing}}
  end

  @doc """
  Overlays CREATE/MODIFY operations onto a `%{path => content}` map.

  Path safety and read-only paths are the parser's job. This function validates
  the operation against the current map: `MODIFY` requires an existing path
  (`:not_found`), and `CREATE` requires a new path (`:already_exists`).
  """
  @spec apply_ops(%{String.t() => binary()}, [{:create | :modify, String.t(), binary()}]) ::
          {:ok, %{String.t() => binary()}}
          | {:error, :already_exists | :not_found | :malformed_op}
  def apply_ops(files, ops) when is_map(files) and is_list(ops) do
    Enum.reduce_while(ops, {:ok, files}, fn
      {:create, path, content}, {:ok, acc} when is_binary(path) ->
        if Map.has_key?(acc, path) do
          {:halt, {:error, :already_exists}}
        else
          {:cont, {:ok, Map.put(acc, path, content)}}
        end

      {:modify, path, content}, {:ok, acc} when is_binary(path) ->
        if Map.has_key?(acc, path) do
          {:cont, {:ok, Map.put(acc, path, content)}}
        else
          {:halt, {:error, :not_found}}
        end

      _op, _acc ->
        {:halt, {:error, :malformed_op}}
    end)
  end

  ## Prompt rendering

  defp render_schema(schema) do
    schema |> Schema.to_map() |> Jason.encode!(pretty: true)
  end

  defp maybe_cap(budget, nil), do: budget
  defp maybe_cap(budget, cap) when is_integer(cap) and cap >= 0, do: min(budget, cap)
  defp maybe_cap(budget, _cap), do: budget

  defp render_docs(docs, _index_file, budget) when budget <= 0 do
    if map_size(docs) == 0,
      do: {:ok, "(no documentation files)", [], []},
      else: {:error, :context_too_large}
  end

  defp render_docs(docs, index_file, budget) do
    paths =
      [index_file | Map.keys(docs) |> Enum.sort()]
      |> Enum.uniq()
      |> Enum.filter(&Map.has_key?(docs, &1))

    case Enum.reduce_while(paths, {[], budget, [], []}, fn path,
                                                           {acc, remaining, writable, read_only} ->
           case render_doc(path, Map.fetch!(docs, path), path == index_file, remaining) do
             {:ok, block, used, :writable} ->
               {:cont, {[block | acc], max(remaining - used, 0), [path | writable], read_only}}

             {:ok, block, used, :read_only} ->
               {:cont, {[block | acc], max(remaining - used, 0), writable, [path | read_only]}}

             {:omit, :read_only} ->
               {:cont, {acc, remaining, writable, [path | read_only]}}

             {:error, :context_too_large} ->
               {:halt, {:error, :context_too_large}}
           end
         end) do
      {:error, :context_too_large} ->
        {:error, :context_too_large}

      {blocks, _remaining, writable, read_only} ->
        text = blocks |> Enum.reverse() |> Enum.join("\n")

        text =
          if read_only == [] do
            text
          else
            text <>
              "\nRead-only documentation files (content omitted or truncated; do not modify): " <>
              Enum.join(Enum.reverse(read_only), ", ")
          end

        {:ok, if(text == "", do: "(no documentation files)", else: text), Enum.reverse(writable),
         Enum.reverse(read_only)}
    end
  end

  defp render_doc(path, content, true, remaining) do
    header = "=== #{path} ===\n"
    header_size = byte_size(header)

    cond do
      UTF8.binary?(content) ->
        {:error, :context_too_large}

      header_size + byte_size(content) <= remaining ->
        {:ok, header <> content, header_size + byte_size(content), :writable}

      true ->
        {:error, :context_too_large}
    end
  end

  defp render_doc(path, content, false, remaining) do
    header = "=== #{path} ===\n"
    header_size = byte_size(header)

    cond do
      UTF8.binary?(content) ->
        if header_size + byte_size(@binary_marker) <= remaining do
          {:ok, header <> @binary_marker, header_size + byte_size(@binary_marker), :read_only}
        else
          {:omit, :read_only}
        end

      header_size + byte_size(content) <= remaining ->
        {:ok, header <> content, header_size + byte_size(content), :writable}

      header_size + byte_size(@truncated_doc_marker) <= remaining ->
        allowed = remaining - header_size - byte_size(@truncated_doc_marker)
        rendered = UTF8.truncate(content, allowed)
        block = header <> rendered <> @truncated_doc_marker
        {:ok, block, byte_size(block), :read_only}

      true ->
        {:omit, :read_only}
    end
  end

  defp render_diff(diff, max_bytes) do
    if UTF8.binary?(diff) do
      "(binary diff omitted)"
    else
      truncate_with_marker(diff, max_bytes)
    end
  end

  defp truncate_with_marker(content, max_bytes) when byte_size(content) <= max_bytes, do: content

  defp truncate_with_marker(content, max_bytes) do
    allowed = max(max_bytes - byte_size(@truncated_marker), 0)
    UTF8.truncate(content, allowed) <> @truncated_marker
  end

  # Single pass so substituted file content can never introduce a placeholder
  # that a later replacement would expand.
  defp substitute(template, values) do
    Regex.replace(~r/\{\{(schema|docs|diff)\}\}/, template, fn _, key ->
      Map.fetch!(values, key)
    end)
  end

  ## Response parsing

  defp do_parse(text, allowed?, opts) do
    max_ops = Keyword.get(opts, :max_ops, @default_max_ops)
    max_file_bytes = Keyword.get(opts, :max_file_bytes, @default_max_file_bytes)
    read_only = opts |> Keyword.get(:read_only_paths, []) |> MapSet.new()

    lines =
      text
      |> String.replace("\r\n", "\n")
      |> String.split("\n")

    with {:ok, begin_index} <- find_marker(lines, "DOCS_BEGIN", :missing_begin, 0),
         {:ok, end_index} <- find_marker(lines, "DOCS_END", :missing_end, begin_index + 1) do
      if end_index == begin_index + 1 do
        {:ok, []}
      else
        lines
        |> Enum.slice((begin_index + 1)..(end_index - 1)//1)
        |> parse_ops(allowed?, read_only, max_ops, max_file_bytes)
      end
    end
  end

  defp find_marker(lines, marker, error, from) do
    lines
    |> Enum.drop(from)
    |> Enum.find_index(&(String.trim(&1) == marker))
    |> case do
      nil -> {:error, error}
      index -> {:ok, index + from}
    end
  end

  defp parse_ops(lines, allowed?, read_only, max_ops, max_file_bytes) do
    lines
    |> Enum.drop_while(&blank?/1)
    |> do_parse_ops(allowed?, read_only, max_ops, max_file_bytes, [], MapSet.new())
  end

  defp do_parse_ops([], _allowed?, _read_only, _max_ops, _max_file_bytes, ops, _seen),
    do: {:ok, Enum.reverse(ops)}

  defp do_parse_ops([line | rest], allowed?, read_only, max_ops, max_file_bytes, ops, seen) do
    with {:ok, kind, path} <- parse_header(line),
         :ok <- check_allowed(path, allowed?),
         :ok <- check_read_only(path, read_only),
         :ok <- check_duplicate(path, seen),
         :ok <- check_count(length(ops), max_ops),
         {:ok, content, remaining} <- take_content(rest, max_file_bytes) do
      do_parse_ops(
        remaining,
        allowed?,
        read_only,
        max_ops,
        max_file_bytes,
        [{kind, path, content} | ops],
        MapSet.put(seen, path)
      )
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

  defp check_allowed(path, allowed?) do
    if allowed?.(path), do: :ok, else: {:error, :unknown_path}
  end

  defp check_read_only(path, read_only) do
    if MapSet.member?(read_only, path), do: {:error, :read_only_path}, else: :ok
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

  defp heading?(content, name) when is_binary(content) do
    Regex.match?(~r/^\#{1,6}\s+#{Regex.escape(name)}\s*$/m, content)
  end

  defp heading?(_content, _name), do: false

  defp blank?(line), do: String.trim(line) == ""
end
