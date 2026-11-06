defmodule Cadence.Shared.Docs.Trigger do
  @moduledoc """
  Decides whether a commit should run the documentation agent (spec §9.2).

  Doc automation is intentionally not run on every commit. A change runs the
  agent when:

    * `.caddocs.yaml` changed,
    * a changed path matches a section's `generated_from` glob, or
    * a changed `.ex`/`.exs` line touches a public API surface — an exported
      `def`/`defmacro`/`defguard`/`defdelegate` or a module attribute.

  API-surface detection is a heuristic over changed lines. Files larger than
  `#{20_000}` lines are treated conservatively as API-affecting.
  """

  alias Cadence.Shared.Docs.Schema
  alias Cadence.Shared.Glob

  @max_scan_lines 20_000

  @api_line ~r/^\s*(?:def\s+|defmacro\s+|defguard\s+|defdelegate\s+|@[a-z_])/

  @doc """
  Returns `{:run, reasons}` or `:skip` for a list of
  `Cadence.Shared.GitStore.diff_trees/3` change maps.

  Manual syncs (`:CadDocSync`) bypass this function.
  """
  @spec reasons(Schema.t(), [map()]) :: {:run, [atom()]} | :skip
  def reasons(%Schema{} = schema, changes) when is_list(changes) do
    reasons =
      []
      |> maybe_add(:schema_changed, schema_changed?(changes))
      |> maybe_add(:generated_from, Enum.any?(changes, &generated_from_match?(schema, &1)))
      |> maybe_add(:api_surface, Enum.any?(changes, &api_surface_change?/1))

    case reasons do
      [] -> :skip
      reasons -> {:run, Enum.reverse(reasons)}
    end
  end

  def reasons(_schema, _changes), do: :skip

  defp maybe_add(reasons, reason, true), do: [reason | reasons]
  defp maybe_add(reasons, _reason, false), do: reasons

  defp schema_changed?(changes) do
    Enum.any?(changes, &(&1.path == Schema.schema_file()))
  end

  defp generated_from_match?(schema, %{path: path}) when is_binary(path) do
    Enum.any?(schema.sections, fn section ->
      is_binary(section.generated_from) and Glob.match?(section.generated_from, path)
    end)
  end

  defp generated_from_match?(_schema, _change), do: false

  defp api_surface_change?(%{path: path} = change) when is_binary(path) do
    String.ends_with?(path, [".ex", ".exs"]) and
      api_line_changed?(Map.get(change, :old_content), Map.get(change, :new_content))
  end

  defp api_surface_change?(_change), do: false

  defp api_line_changed?(old_content, new_content) do
    with true <- text_content?(old_content),
         true <- text_content?(new_content) do
      old_lines = lines(old_content)
      new_lines = lines(new_content)

      if length(old_lines) > @max_scan_lines or length(new_lines) > @max_scan_lines do
        true
      else
        old_set = MapSet.new(old_lines)
        new_set = MapSet.new(new_lines)

        added = Enum.reject(new_lines, &MapSet.member?(old_set, &1))
        removed = Enum.reject(old_lines, &MapSet.member?(new_set, &1))

        Enum.any?(added ++ removed, &Regex.match?(@api_line, &1))
      end
    else
      false -> false
    end
  end

  defp text_content?(nil), do: true

  defp text_content?(content) when is_binary(content) do
    not Cadence.Shared.UTF8.binary?(content)
  end

  defp text_content?(_content), do: false

  defp lines(nil), do: []
  defp lines(content) when is_binary(content), do: String.split(content, "\n")
end
