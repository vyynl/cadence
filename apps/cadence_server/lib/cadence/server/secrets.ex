defmodule Cadence.Server.Secrets do
  @moduledoc """
  Runtime secret resolution for AshAuthentication.

  All values come from `config/runtime.exs` (which reads `CAD_*` env vars).
  Missing optional OAuth credentials are reported as `:error`, so the server
  boots without OAuth configured but refuses that provider's sign-in.
  """

  use AshAuthentication.Secret

  @impl AshAuthentication.Secret
  def secret_for(
        [:authentication, :tokens, :signing_secret],
        _resource,
        _opts,
        _context
      ) do
    fetch(:token_signing_secret)
  end

  def secret_for(
        [:authentication, :strategies, provider, key],
        _resource,
        _opts,
        _context
      )
      when provider in [:github, :google] and
             key in [:client_id, :client_secret, :redirect_uri] do
    :cadence_server
    |> Application.get_env(:oauth, [])
    |> Keyword.get(provider, [])
    |> Keyword.get(key)
    |> case do
      nil -> :error
      value -> {:ok, value}
    end
  end

  def secret_for(_path, _resource, _opts, _context), do: :error

  defp fetch(key) do
    case Application.fetch_env(:cadence_server, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> :error
    end
  end
end
