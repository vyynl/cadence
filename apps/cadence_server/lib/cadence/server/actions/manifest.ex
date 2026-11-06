defmodule Cadence.Server.Actions.Manifest do
  @moduledoc """
  Parses and validates a project's `actions/manifest.json` (spec §8.2).

  The manifest is client-pushed repository content, so validation is strict and
  every failure is a shape-only error: the web layer hides the panel instead of
  rendering a partial manifest. Unknown keys are ignored so the format can grow
  without breaking older servers.
  """

  @default_max_bytes 32_768
  @default_max_actions 20
  @max_command_bytes 512
  @max_description_bytes 200
  @name_format ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/
  # C0/C1 controls plus bidi overrides (a description can otherwise spoof its
  # rendered order).
  @control_chars ~r/[\x00-\x1F\x7F-\x9F]/
  @bidi_chars [
    "\u202A",
    "\u202B",
    "\u202C",
    "\u202D",
    "\u202E",
    "\u2066",
    "\u2067",
    "\u2068",
    "\u2069"
  ]

  defmodule Action do
    @moduledoc "One entry from `actions/manifest.json`."
    defstruct [:name, :command, :description, expose: false]

    @type t :: %__MODULE__{
            name: String.t(),
            command: String.t(),
            description: String.t() | nil,
            expose: boolean()
          }
  end

  defstruct actions: []

  @type t :: %__MODULE__{actions: [Action.t()]}

  @doc "Default cap for one manifest, in bytes."
  @spec default_max_bytes() :: pos_integer()
  def default_max_bytes, do: @default_max_bytes

  @doc "Default cap for actions in one manifest."
  @spec default_max_actions() :: pos_integer()
  def default_max_actions, do: @default_max_actions

  @doc """
  Parse a manifest from its JSON bytes.

  Options:

    * `:max_bytes` — reject before decoding (default 32 KiB)
    * `:max_actions` — reject a longer action list (default 20)

  Non-integer or negative caps fall back to the defaults.
  """
  @spec parse(binary(), keyword()) :: {:ok, t()} | {:error, atom()}
  def parse(json, opts \\ [])

  def parse(json, opts) when is_binary(json) do
    max_bytes = cap(opts, :max_bytes, @default_max_bytes)
    max_actions = cap(opts, :max_actions, @default_max_actions)

    with :ok <- check_size(json, max_bytes),
         {:ok, decoded} <- decode(json),
         {:ok, entries} <- entries(decoded),
         :ok <- check_count(entries, max_actions),
         {:ok, actions} <- parse_actions(entries) do
      {:ok, %__MODULE__{actions: actions}}
    end
  end

  def parse(_json, _opts), do: {:error, :invalid_manifest}

  defp cap(opts, key, default) do
    case Keyword.get(opts, key) do
      value when is_integer(value) and value >= 0 -> value
      _value -> default
    end
  end

  defp check_size(json, max_bytes) when byte_size(json) <= max_bytes, do: :ok
  defp check_size(_json, _max_bytes), do: {:error, :too_large}

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp entries(%{"actions" => actions}) when is_list(actions), do: {:ok, actions}
  defp entries(_decoded), do: {:error, :invalid_manifest}

  defp check_count(entries, max_actions) when length(entries) <= max_actions, do: :ok
  defp check_count(_entries, _max_actions), do: {:error, :too_many_actions}

  defp parse_actions(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case parse_action(entry) do
        {:ok, action} -> {:cont, {:ok, acc ++ [action]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, actions} -> check_duplicates(actions)
      {:error, _reason} = error -> error
    end
  end

  defp parse_action(%{} = entry) do
    with {:ok, name} <- name(entry["name"]),
         {:ok, command} <- command(entry["command"]),
         {:ok, description} <- description(entry["description"]),
         {:ok, expose} <- expose(entry["expose"]) do
      {:ok, %Action{name: name, command: command, description: description, expose: expose}}
    end
  end

  defp parse_action(_entry), do: {:error, :invalid_action}

  defp name(value) when is_binary(value) do
    if Regex.match?(@name_format, value), do: {:ok, value}, else: {:error, :invalid_name}
  end

  defp name(_value), do: {:error, :invalid_name}

  defp command(value) when is_binary(value) do
    cond do
      String.trim(value) == "" -> {:error, :invalid_command}
      byte_size(value) > @max_command_bytes -> {:error, :invalid_command}
      invalid_chars?(value) -> {:error, :invalid_command}
      true -> {:ok, value}
    end
  end

  defp command(_value), do: {:error, :invalid_command}

  defp description(nil), do: {:ok, nil}

  defp description(value) when is_binary(value) do
    cond do
      byte_size(value) > @max_description_bytes -> {:error, :invalid_description}
      invalid_chars?(value) -> {:error, :invalid_description}
      true -> {:ok, value}
    end
  end

  defp description(_value), do: {:error, :invalid_description}

  defp invalid_chars?(value) do
    Regex.match?(@control_chars, value) or
      Enum.any?(@bidi_chars, &String.contains?(value, &1))
  end

  defp expose(nil), do: {:ok, false}
  defp expose(value) when is_boolean(value), do: {:ok, value}
  defp expose(_value), do: {:error, :invalid_expose}

  defp check_duplicates(actions) do
    names = Enum.map(actions, & &1.name)

    if length(names) == length(Enum.uniq(names)),
      do: {:ok, actions},
      else: {:error, :duplicate_action}
  end
end
