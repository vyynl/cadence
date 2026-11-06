defmodule Cadence.Shared.Glob do
  @moduledoc """
  Minimal, filesystem-free glob matching for `generated_from` patterns
  (spec §9.1).

  Supported syntax:

    * `**/` — zero or more path segments (so `lib/**/*.ex` matches
      `lib/foo.ex` and `lib/a/b.ex`)
    * `**` — any characters, including `/`
    * `*` — any characters except `/`
    * `?` — one character except `/`
    * everything else is literal

  `Path.wildcard/1` is deliberately not used: it reads the filesystem, and the
  trigger must match paths from a diff without touching disk.
  """

  @spec match?(String.t(), String.t()) :: boolean()
  def match?(pattern, path) when is_binary(pattern) and is_binary(path) do
    case compile(pattern) do
      {:ok, regex} -> Regex.match?(regex, path)
      {:error, _reason} -> false
    end
  end

  def match?(_pattern, _path), do: false

  @spec compile(String.t()) :: {:ok, Regex.t()} | {:error, :empty_pattern | :invalid_pattern}
  def compile(pattern) when is_binary(pattern) do
    if pattern == "" do
      {:error, :empty_pattern}
    else
      case Regex.compile("^" <> to_regex(pattern) <> "$") do
        {:ok, regex} -> {:ok, regex}
        {:error, _reason} -> {:error, :invalid_pattern}
      end
    end
  end

  def compile(_pattern), do: {:error, :invalid_pattern}

  defp to_regex("**/" <> rest), do: "(?:[^/]+/)*" <> to_regex(rest)
  defp to_regex("**" <> rest), do: ".*" <> to_regex(rest)
  defp to_regex("*" <> rest), do: "[^/]*" <> to_regex(rest)
  defp to_regex("?" <> rest), do: "[^/]" <> to_regex(rest)
  defp to_regex(<<char::utf8, rest::binary>>), do: Regex.escape(<<char::utf8>>) <> to_regex(rest)
  defp to_regex(""), do: ""
end
