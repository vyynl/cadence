defmodule Cadence.Server.Accounts do
  @moduledoc """
  Server-side accounts: OAuth identities and daemon API keys.

  Human users authenticate with GitHub or Google; daemons authenticate with
  personal access tokens modelled as AshAuthentication API keys (spec §7.4,
  §10.1).
  """

  use Ash.Domain

  resources do
    resource(Cadence.Server.Accounts.User)
    resource(Cadence.Server.Accounts.Token)
    resource(Cadence.Server.Accounts.UserIdentity)
    resource(Cadence.Server.Accounts.ApiKey)
  end

  @doc """
  Verifies a daemon API key and returns its user.

  Used by the websocket socket, where there is no `Plug.Conn` for the HTTP
  API-key plug to operate on.
  """
  @spec authenticate_api_key(term()) :: {:ok, Ash.Resource.record()} | {:error, :invalid_api_key}
  def authenticate_api_key(api_key) when is_binary(api_key) and api_key != "" do
    case Cadence.Server.Accounts.User
         |> Ash.Query.for_read(:sign_in_with_api_key, %{api_key: api_key})
         |> Ash.read_one(domain: __MODULE__) do
      {:ok, %Cadence.Server.Accounts.User{} = user} -> {:ok, user}
      _ -> {:error, :invalid_api_key}
    end
  end

  def authenticate_api_key(_api_key), do: {:error, :invalid_api_key}

  @doc """
  Load users by ID for the membership read view.

  Returns a `%{user_id => user}` map; missing/deleted users are omitted.
  """
  @spec users_by_ids([Ecto.UUID.t() | String.t()]) :: %{
          optional(String.t()) => Ash.Resource.record()
        }
  def users_by_ids(ids) when is_list(ids) do
    Enum.reduce(ids, %{}, fn id, acc ->
      case Ash.get(Cadence.Server.Accounts.User, id, domain: __MODULE__) do
        {:ok, user} -> Map.put(acc, user.id, user)
        _ -> acc
      end
    end)
  end

  @doc """
  Issues a personal access token for a daemon.

  The plaintext key is available exactly once in
  `api_key.__metadata__.plaintext_api_key`; only its hash is persisted.
  """
  def create_api_key(user, name) do
    Ash.create(
      Cadence.Server.Accounts.ApiKey,
      %{user_id: user.id, name: name},
      action: :create,
      actor: user
    )
  end
end
