defmodule Cadence.Daemon.TUI.Diff do
  @moduledoc """
  Pure formatter for node and docs diff payloads.

  `GET /diff` and `GET /docs/diff` return the same JSON shape the Neovim plugin
  renders: `files` with a path, status, `binary`/`truncated` flags, and
  `ctx`/`add`/`del`/`skip` lines. This module turns that into a flat
  list of `%{kind: kind, text: text}` rows so the scene can style them
  without knowing the wire format. The output mirrors
  `cadence.nvim/lua/cadence/diff.lua` so both frontends read the same.
  """

  @type kind :: :file | :add | :del | :ctx | :skip | :note
  @type line :: %{kind: kind(), text: String.t()}

  @prefix %{"add" => "+", "del" => "-", "ctx" => " "}

  @doc """
  Formats a diff payload into display rows.

  Options:

    * `:empty` - text for a payload with no files (default `"(no changes)"`).
      Docs callers pass `"(no docs changes)"`.

  An `{:error, %{message: message}}` tuple formats as a single `:note` row, so
  the scene can render HTTP failures (for example the `409` "no docs commit")
  in the same pane as a diff.
  """
  @spec format(map() | nil | {:error, term()}, keyword()) :: [line()]
  def format(payload, opts \\ []) do
    empty = Keyword.get(opts, :empty, "(no changes)")

    case payload do
      nil -> note(empty)
      {:error, %{message: message}} -> note(message)
      {:error, message} when is_binary(message) -> note(message)
      %{"files" => []} -> note(empty)
      %{"files" => files} when is_list(files) -> format_files(files, payload, empty)
      _other -> note(empty)
    end
  end

  @doc "A single `:note` row."
  @spec note(String.t()) :: [line()]
  def note(text), do: [%{kind: :note, text: text}]

  defp format_files(files, payload, _empty) do
    rows = Enum.flat_map(files, &format_file/1)

    if payload["truncated"] == true do
      rows ++ note("… more files omitted")
    else
      rows
    end
  end

  defp format_file(file) do
    path = file["path"] || "?"
    status = file["status"] || "?"

    header = [%{kind: :file, text: "#{path}  (#{status})"}]
    header ++ body(file) ++ truncated(file)
  end

  defp body(%{"binary" => true}), do: [%{kind: :note, text: "  (binary file)"}]

  defp body(file) do
    Enum.map(file["lines"] || [], fn line ->
      case line["kind"] do
        "skip" ->
          %{kind: :skip, text: "  …"}

        kind ->
          prefix = Map.get(@prefix, kind, " ")
          %{kind: kind_atom(kind), text: prefix <> " " <> (line["text"] || "")}
      end
    end)
  end

  defp truncated(%{"truncated" => true}), do: [%{kind: :note, text: "  … (truncated)"}]
  defp truncated(_file), do: []

  defp kind_atom("add"), do: :add
  defp kind_atom("del"), do: :del
  defp kind_atom("ctx"), do: :ctx
  defp kind_atom(_kind), do: :ctx
end
