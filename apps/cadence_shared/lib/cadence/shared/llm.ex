defmodule Cadence.Shared.LLM do
  @moduledoc """
  Thin wrapper over `AxiomAi` for Cadence's LLM needs (commit messages today;
  melds and doc automation later).

  Configuration is read from the application environment
  (`:cadence_shared, Cadence.Shared.LLM`), populated from `CAD_LLM_*` env vars
  in `config/runtime.exs`. No secrets are ever inlined here.

  When no `api_key` is configured the client degrades gracefully: `complete/1`
  returns `{:error, :not_configured}` and callers fall back to non-AI behavior
  (local-first, spec §15).
  """

  @provider_atoms %{
    "deepseek" => :deepseek,
    "openai" => :openai,
    "anthropic" => :anthropic
  }

  @doc "The configured model name, or `nil` when unset."
  @spec model() :: String.t() | nil
  def model do
    config()[:model]
  end

  @doc """
  Sends `prompt` to the configured provider and returns `{:ok, text}` on
  success or `{:error, reason}` on failure.
  """
  @spec complete(String.t()) :: {:ok, String.t()} | {:error, term()}
  def complete(prompt) when is_binary(prompt) do
    case api_key() do
      key when key in [nil, ""] ->
        {:error, :not_configured}

      _ ->
        client = AxiomAi.new(provider_atom(config()[:provider]), client_config())

        case AxiomAi.complete(client, prompt) do
          {:ok, %{completion: text}} when is_binary(text) -> {:ok, text}
          {:ok, %{response: text}} when is_binary(text) -> {:ok, text}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp config do
    Application.get_env(:cadence_shared, __MODULE__, [])
  end

  defp api_key, do: config()[:api_key]

  defp provider_atom(provider) when is_atom(provider), do: provider

  defp provider_atom(provider) when is_binary(provider),
    do: Map.get(@provider_atoms, provider, :deepseek)

  defp provider_atom(_), do: :deepseek

  defp client_config do
    %{
      api_key: config()[:api_key],
      model: config()[:model] || "deepseek-chat",
      base_url: config()[:base_url] || "https://api.deepseek.com"
    }
  end
end
