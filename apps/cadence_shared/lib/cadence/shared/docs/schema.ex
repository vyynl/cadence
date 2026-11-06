defmodule Cadence.Shared.Docs.Schema do
  @moduledoc """
  Parsed project documentation schema (`.caddocs.yaml`, spec §9.1).

  Parsing is strict about the shape the doc agent depends on (paths, sections,
  `max_words`, `generated_from`) and returns descriptive error atoms. Paths are
  validated as relative, traversal-free paths; the agent may only write the
  index file or files under `docs_dir`.
  """

  alias Cadence.Shared.Glob

  @schema_file ".caddocs.yaml"

  defmodule Section do
    @moduledoc "One documentation section from the schema."

    @enforce_keys [:name]
    defstruct [
      :name,
      :max_words,
      :generated_from,
      required: false,
      auto_append: false
    ]
  end

  @enforce_keys [:index_file, :docs_dir, :sections]
  defstruct [:index_file, :docs_dir, :sections]

  @type section :: %Section{
          name: String.t(),
          required: boolean(),
          max_words: pos_integer() | nil,
          generated_from: String.t() | nil,
          auto_append: boolean()
        }

  @type t :: %__MODULE__{
          index_file: String.t(),
          docs_dir: String.t(),
          sections: [section()]
        }

  @doc "The project-relative schema file name."
  @spec schema_file() :: String.t()
  def schema_file, do: @schema_file

  @doc """
  Parses a `.caddocs.yaml` document.

  Returns `{:ok, schema}` or `{:error, reason}` where `reason` is one of
  `:invalid_yaml`, `:missing_index_file`, `:invalid_index_file`,
  `:invalid_docs_dir`, `:missing_sections`, `:invalid_section`,
  `:invalid_section_name`, `:duplicate_section`, `:invalid_max_words`,
  `:invalid_generated_from`, `:invalid_required`, or `:invalid_auto_append`.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, atom()}
  def parse(yaml) when is_binary(yaml) do
    with {:ok, data} <- decode(yaml),
         {:ok, map} <- as_map(data),
         {:ok, index_file} <- index_file(map),
         {:ok, docs_dir} <- docs_dir(map),
         {:ok, sections} <- sections(Map.get(map, "sections")) do
      {:ok, %__MODULE__{index_file: index_file, docs_dir: docs_dir, sections: sections}}
    end
  end

  def parse(_yaml), do: {:error, :invalid_yaml}

  @doc "Whether `path` is writable by the doc agent for this schema."
  @spec allowed_path?(t(), String.t()) :: boolean()
  def allowed_path?(%__MODULE__{} = schema, path) when is_binary(path) do
    safe_path?(path) and
      (path == schema.index_file or String.starts_with?(path, schema.docs_dir <> "/"))
  end

  def allowed_path?(_schema, _path), do: false

  @doc "The schema's writable roots (the index file and the docs directory)."
  @spec doc_roots(t()) :: [String.t()]
  def doc_roots(%__MODULE__{} = schema), do: [schema.index_file, schema.docs_dir]

  @doc "A JSON-friendly map for caching in `Project.docs_schema`."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = schema) do
    %{
      "index_file" => schema.index_file,
      "docs_dir" => schema.docs_dir,
      "sections" => Enum.map(schema.sections, &section_to_map/1)
    }
  end

  defp section_to_map(%Section{} = section) do
    %{
      "name" => section.name,
      "required" => section.required,
      "max_words" => section.max_words,
      "generated_from" => section.generated_from,
      "auto_append" => section.auto_append
    }
  end

  ## YAML decoding

  defp decode(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, data} -> {:ok, data}
      {:error, _reason} -> {:error, :invalid_yaml}
    end
  rescue
    _error -> {:error, :invalid_yaml}
  end

  defp as_map(map) when is_map(map), do: {:ok, map}
  defp as_map(_data), do: {:error, :invalid_yaml}

  ## Top-level fields

  defp index_file(map) do
    case Map.get(map, "index_file") do
      path when is_binary(path) and path != "" ->
        if safe_path?(path) and not String.ends_with?(path, "/") do
          {:ok, path}
        else
          {:error, :invalid_index_file}
        end

      _ ->
        {:error, :missing_index_file}
    end
  end

  defp docs_dir(map) do
    case Map.get(map, "docs_dir", "docs") do
      dir when is_binary(dir) and dir != "" ->
        normalized = String.trim_trailing(dir, "/")

        if normalized != "" and safe_path?(normalized) do
          {:ok, normalized}
        else
          {:error, :invalid_docs_dir}
        end

      _ ->
        {:error, :invalid_docs_dir}
    end
  end

  defp sections(sections) when is_list(sections) and sections != [] do
    sections
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn section, {:ok, acc, seen} ->
      with {:ok, parsed} <- section(section),
           :ok <- unique_name(parsed.name, seen) do
        {:cont, {:ok, [parsed | acc], MapSet.put(seen, parsed.name)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parsed, _seen} -> {:ok, Enum.reverse(parsed)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sections(_sections), do: {:error, :missing_sections}

  defp section(%{} = map) do
    with {:ok, name} <- section_name(Map.get(map, "name")),
         {:ok, required} <- boolean(map, "required", false, :invalid_required),
         {:ok, auto_append} <- boolean(map, "auto_append", false, :invalid_auto_append),
         {:ok, max_words} <- max_words(Map.get(map, "max_words")),
         {:ok, generated_from} <- generated_from(Map.get(map, "generated_from")) do
      {:ok,
       %Section{
         name: name,
         required: required,
         max_words: max_words,
         generated_from: generated_from,
         auto_append: auto_append
       }}
    end
  end

  defp section(_section), do: {:error, :invalid_section}

  defp section_name(name) when is_binary(name) do
    if name != "" and safe_text?(name), do: {:ok, name}, else: {:error, :invalid_section_name}
  end

  defp section_name(_name), do: {:error, :invalid_section_name}

  defp unique_name(name, seen) do
    if MapSet.member?(seen, name), do: {:error, :duplicate_section}, else: :ok
  end

  defp boolean(map, key, default, error) do
    case Map.get(map, key, default) do
      value when is_boolean(value) -> {:ok, value}
      _value -> {:error, error}
    end
  end

  defp max_words(nil), do: {:ok, nil}
  defp max_words(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp max_words(_value), do: {:error, :invalid_max_words}

  defp generated_from(nil), do: {:ok, nil}

  defp generated_from(pattern) when is_binary(pattern) and pattern != "" do
    case Glob.compile(pattern) do
      {:ok, _regex} -> {:ok, pattern}
      {:error, _reason} -> {:error, :invalid_generated_from}
    end
  end

  defp generated_from(_pattern), do: {:error, :invalid_generated_from}

  ## Path safety

  defp safe_path?(path) when is_binary(path) and path != "" do
    safe_text?(path) and
      not String.starts_with?(path, "/") and
      not String.contains?(path, "\\") and
      path
      |> String.split("/")
      |> Enum.all?(fn segment -> segment not in ["", ".", ".."] end)
  end

  defp safe_path?(_path), do: false

  defp safe_text?(text) when is_binary(text) do
    String.valid?(text) and not Regex.match?(~r/[\x00-\x1F\x7F]/, text)
  end
end
