defmodule Cadence.Server.PublicContent do
  @moduledoc """
  Server-side filtering for content exposed to anonymous visitors.

  This is best-effort defense-in-depth: it hides obviously sensitive paths and
  redacts high-confidence token patterns before content reaches the browser. It
  never logs matched values or file content.
  """

  @patterns [
    %{
      name: :private_key,
      regex: ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----/s
    },
    %{name: :aws_access_key, regex: ~r/\bAKIA[0-9A-Z]{16}\b/},
    %{name: :github_token, regex: ~r/\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}\b/},
    %{name: :github_pat, regex: ~r/\bgithub_pat_[A-Za-z0-9_]{20,}\b/},
    %{name: :gitlab_token, regex: ~r/\bglpat-[A-Za-z0-9\-_]{20,}\b/},
    %{name: :slack_token, regex: ~r/\bxox[baprs]-[A-Za-z0-9-]{10,}\b/},
    %{name: :stripe_live_key, regex: ~r/\b(?:sk|rk)_live_[A-Za-z0-9]{16,}\b/},
    %{name: :anthropic_key, regex: ~r/\bsk-ant-[A-Za-z0-9\-_]{20,}\b/},
    %{name: :openai_key, regex: ~r/\bsk-[A-Za-z0-9]{20,}\b/},
    %{name: :google_api_key, regex: ~r/\bAIza[0-9A-Za-z\-_]{35}\b/},
    %{
      name: :jwt,
      regex: ~r/\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/
    },
    %{
      name: :generic_assignment,
      regex:
        ~r/\b(?:api[_-]?key|secret|token|password|passwd|pwd|client[_-]?secret)\b\s*[:=]\s*["']?[A-Za-z0-9_\-\.\/\+=]{12,}["']?/i
    }
  ]

  @sensitive_basename_patterns [
    ~r/^\.env($|\.)/i,
    ~r/\.(pem|key|p12|pfx|jks|keystore)$/i,
    ~r/^id_(rsa|dsa|ecdsa|ed25519)/i,
    ~r/\.ppk$/i,
    ~r/^\.npmrc$/i,
    ~r/^\.pypirc$/i,
    ~r/^\.netrc$/i,
    ~r/^\.git-credentials$/i,
    ~r/^credentials/i,
    ~r/^secrets?\./i,
    ~r/\.secrets?$/i
  ]

  @example_patterns [~r/\.(example|sample|template)$/i]

  @doc """
  Redact high-confidence secret patterns from `text`.

  Returns `{redacted_text, findings}` where `findings` contains pattern names
  only. Never log the input or output. Invalid UTF-8 is returned unchanged
  (binary files are handled separately).
  """
  @spec redact(String.t()) :: {String.t(), [atom()]}
  def redact(text) when is_binary(text) do
    if String.valid?(text) do
      {redacted, findings} =
        Enum.reduce(@patterns, {text, []}, fn %{name: name, regex: regex}, {acc, findings} ->
          if Regex.match?(regex, acc) do
            {Regex.replace(regex, acc, fn _match -> "[REDACTED]" end), [name | findings]}
          else
            {acc, findings}
          end
        end)

      {redacted, findings |> Enum.reverse() |> Enum.uniq()}
    else
      {text, []}
    end
  end

  @doc "Redact a commit message, returning `nil` for `nil`."
  @spec redact_message(String.t() | nil) :: String.t() | nil
  def redact_message(nil), do: nil
  def redact_message(text) when is_binary(text), do: text |> redact() |> elem(0)

  @doc "Return whether `text` contains a high-confidence secret pattern."
  @spec sensitive?(String.t()) :: boolean()
  def sensitive?(text) when is_binary(text), do: text |> findings() != []

  @doc "Return the pattern names detected in `text`."
  @spec findings(String.t()) :: [atom()]
  def findings(text) when is_binary(text), do: text |> redact() |> elem(1)

  @doc "Return whether a path is a sensitive filename by basename."
  @spec sensitive_path?(String.t()) :: boolean()
  def sensitive_path?(path) when is_binary(path) do
    basename = Path.basename(path)
    Enum.any?(@sensitive_basename_patterns, &Regex.match?(&1, basename))
  end

  @doc """
  Return whether a sensitive-looking filename is an allowed example/template.

  Allowed examples are still content-scanned and redacted; they are not
  quarantined solely because of their name.
  """
  @spec allowed_sensitive_path?(String.t()) :: boolean()
  def allowed_sensitive_path?(path) when is_binary(path) do
    basename = Path.basename(path)
    Enum.any?(@example_patterns, &Regex.match?(&1, basename))
  end

  @doc "Filter entries, hiding sensitive paths except allowed examples."
  @spec filter_entries([map()]) :: {[map()], non_neg_integer()}
  def filter_entries(entries) when is_list(entries) do
    {visible, hidden} =
      Enum.split_with(entries, fn entry ->
        not sensitive_path?(entry.path) or allowed_sensitive_path?(entry.path)
      end)

    {visible, length(hidden)}
  end

  @doc "Return whether content is binary (NUL or invalid UTF-8)."
  @spec binary?(binary()) :: boolean()
  def binary?(content) when is_binary(content) do
    not String.valid?(content) or :binary.match(content, <<0>>) != :nomatch
  end

  @doc """
  Return whether a snapshot must be quarantined.

  Quarantine is triggered by a sensitive path that is not an allowed example or
  by a high-confidence secret pattern in any text blob. The caller should also
  quarantine when the snapshot cannot be fully scanned (file/byte caps).
  """
  @spec quarantine?([map()]) :: boolean()
  def quarantine?([]), do: false

  def quarantine?(blobs) when is_list(blobs) do
    Enum.any?(blobs, fn %{path: path, content: content} ->
      (sensitive_path?(path) and not allowed_sensitive_path?(path)) or sensitive?(content)
    end)
  end
end
