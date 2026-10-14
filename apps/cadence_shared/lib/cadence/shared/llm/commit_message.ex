defmodule Cadence.Shared.LLM.CommitMessage do
  @moduledoc """
  Prompt building and response guardrails for AI-generated commit messages
  (spec §5.5).

  Pure functions with no I/O except `build_prompt/1`, which reads the prompt
  template from `cadence_shared/priv/prompts/commit_message.txt`. The parser
  clamps the suggested flag so the AI can never auto-promote a node to
  `functioning` (spec §3.1).
  """

  @flag_atoms %{
    "functioning" => :functioning,
    "in-progress" => :"in-progress",
    "broken" => :broken
  }

  @default_flag :"in-progress"

  @doc """
  Builds the full prompt by injecting `diff_text` into the prompt template.
  """
  @spec build_prompt(String.t()) :: String.t()
  def build_prompt(diff_text) when is_binary(diff_text) do
    template_path = Application.app_dir(:cadence_shared, "priv/prompts/commit_message.txt")

    template_path
    |> File.read!()
    |> String.replace("{{diff}}", diff_text)
  end

  @doc """
  Parses an LLM response into `{:ok, %{summary, flag, details}}` or
  `{:error, reason}`. A missing/blank summary is a hard failure; an absent or
  unrecognized flag yields `flag: nil` (callers apply the default).
  """
  @spec parse(String.t()) ::
          {:ok, %{summary: String.t(), flag: atom() | nil, details: [String.t()]}}
          | {:error, atom()}
  def parse(text) when is_binary(text) do
    lines =
      text
      |> String.split(~r/\r?\n/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case extract_field(lines, "SUMMARY:") do
      nil ->
        {:error, :missing_summary}

      "" ->
        {:error, :missing_summary}

      summary ->
        {:ok,
         %{
           summary: summary,
           flag: parse_flag(extract_field(lines, "FLAG:")),
           details: extract_details(lines)
         }}
    end
  end

  @doc """
  Clamps a suggested flag so the AI can never promote a node to `functioning`
  (spec §3.1). `functioning` collapses to `in-progress`; anything unrecognized
  falls back to `in-progress`.
  """
  @spec clamp_flag(atom() | nil) :: :"in-progress" | :broken
  def clamp_flag(:functioning), do: @default_flag
  def clamp_flag(flag) when flag in [:"in-progress", :broken], do: flag
  def clamp_flag(_), do: @default_flag

  @doc """
  Renders the final human-facing message from a parsed result: the summary on
  its own line, followed by detail bullets when present.
  """
  @spec render(map()) :: String.t()
  def render(%{summary: summary, details: details}) do
    case details do
      [] -> summary
      details -> Enum.join([summary, "" | Enum.map(details, &"- #{&1}")], "\n")
    end
  end

  @doc """
  Renders a list of `GitStore.diff_trees/3` change maps into prompt text:
  a `A`/`M`/`D` path list, with new content inlined for added/modified files.

  File contents larger than `max_bytes` are truncated (and marked) to bound
  prompt/token cost.
  """
  @spec diff_to_text([map()], non_neg_integer() | nil) :: String.t()
  def diff_to_text(changes, max_bytes \\ nil) do
    changes
    |> Enum.map(&render_change(&1, max_bytes))
    |> Enum.join("\n\n")
  end

  defp render_change(%{path: path, status: :added, new_content: content}, max_bytes) do
    ["A #{path}", truncate(content, max_bytes)] |> Enum.join("\n")
  end

  defp render_change(%{path: path, status: :modified, new_content: content}, max_bytes) do
    ["M #{path}", truncate(content, max_bytes)] |> Enum.join("\n")
  end

  defp render_change(%{path: path, status: :deleted}, _max_bytes) do
    "D #{path}"
  end

  defp truncate(content, max_bytes) when is_binary(content) and is_integer(max_bytes) do
    if byte_size(content) > max_bytes do
      binary_part(content, 0, max_bytes) <> "\n... (truncated)"
    else
      content
    end
  end

  defp truncate(content, _max_bytes), do: content

  defp extract_field(lines, prefix) do
    case Enum.find(lines, &String.starts_with?(&1, prefix)) do
      nil -> nil
      line -> line |> String.replace_prefix(prefix, "") |> String.trim()
    end
  end

  defp parse_flag(nil), do: nil
  defp parse_flag(""), do: nil
  defp parse_flag(flag), do: Map.get(@flag_atoms, flag)

  defp extract_details(lines) do
    lines
    |> Enum.drop_while(&(not String.starts_with?(&1, "DETAIL:")))
    |> Enum.drop(1)
    |> Enum.filter(&String.starts_with?(&1, "-"))
    |> Enum.map(&(&1 |> String.replace_prefix("-", "") |> String.trim()))
  end
end
