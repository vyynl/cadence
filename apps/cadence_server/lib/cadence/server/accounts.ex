defmodule Cadence.Server.Accounts do
  @moduledoc """
  Server-side accounts: local passwords, TOTP, OAuth identities, DB sessions,
  and daemon API keys.

  Humans sign in with an operator-created local password + TOTP; GitHub/Google
  OAuth and passkeys are secondary. Daemons authenticate with personal access
  tokens modelled as AshAuthentication API keys (spec §7.4, §10.1).
  """

  use Ash.Domain

  require Ash.Query

  resources do
    resource(Cadence.Server.Accounts.User)
    resource(Cadence.Server.Accounts.Token)
    resource(Cadence.Server.Accounts.UserIdentity)
    resource(Cadence.Server.Accounts.ApiKey)
    resource(Cadence.Server.Accounts.WebAuthnCredential)
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

  Reads the whole list in one query (`id in ids`). Returns a
  `%{user_id => user}` map; users that are missing/deleted are omitted, as are
  ids that cannot be cast to a UUID (any term is accepted and dropped). A list
  with no usable ids returns `%{}` without querying, so the membership panel
  never pays for an empty panel.

  Keys are always canonical lowercase UUID strings, even when an id is passed
  in the raw 16-byte form; a caller holding the raw form must normalise it
  (`Ecto.UUID.load!/1`) before `Map.get/2`.

  Reads are batched but not swallowed: an infrastructure failure raises
  (`Ash.read!`), because a partial identity map silently degrades the UI.
  """
  @spec users_by_ids([term()]) :: %{
          optional(String.t()) => Ash.Resource.record()
        }
  def users_by_ids(ids) when is_list(ids) do
    ids =
      ids
      |> Enum.map(&cast_id/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case ids do
      [] ->
        %{}

      ids ->
        Cadence.Server.Accounts.User
        |> Ash.Query.filter(id in ^ids)
        |> Ash.read!(domain: __MODULE__)
        |> Map.new(&{&1.id, &1})
    end
  end

  # Ids are cast before the query: one malformed element would otherwise fail
  # the whole batch, so a bad id is dropped rather than poisoning every lookup.
  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
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

  @doc """
  Lists one account's daemon tokens, oldest first.

  Scoping **is** the authorization boundary: this domain installs no Ash
  authorizer, so a read without the `user_id` filter would return every
  account's rows. Expired tokens are included so they can still be revoked
  (they are already rejected at authentication time).
  """
  @spec list_api_keys(Cadence.Server.Accounts.User.t()) ::
          {:ok, [Cadence.Server.Accounts.ApiKey.t()]} | {:error, :storage_error}
  def list_api_keys(%Cadence.Server.Accounts.User{id: user_id}) do
    Cadence.Server.Accounts.ApiKey
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.read(domain: __MODULE__)
    |> case do
      {:ok, api_keys} -> {:ok, api_keys}
      {:error, _error} -> {:error, :storage_error}
    end
  end

  @doc """
  Revokes (deletes) one daemon token owned by `user`.

  The lookup is scoped to the account, so a malformed id, an unknown id, or
  another account's token is `:not_found` and changes nothing. The row is
  deleted rather than marked: the hash is the credential, and the
  AshAuthentication API-key strategy already treats a missing row as invalid.
  """
  @spec revoke_api_key(Cadence.Server.Accounts.User.t(), term()) ::
          :ok | {:error, :not_found | :storage_error}
  def revoke_api_key(%Cadence.Server.Accounts.User{} = user, id) do
    with {:ok, api_key} <- fetch_api_key(user, id) do
      case Ash.destroy(api_key, domain: __MODULE__) do
        :ok -> :ok
        {:ok, _api_key} -> :ok
        {:error, _error} -> {:error, :storage_error}
      end
    end
  end

  defp fetch_api_key(%Cadence.Server.Accounts.User{id: user_id}, id) when is_binary(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id) do
      Cadence.Server.Accounts.ApiKey
      |> Ash.Query.filter(id == ^uuid and user_id == ^user_id)
      |> Ash.read_one(domain: __MODULE__)
      |> case do
        {:ok, %Cadence.Server.Accounts.ApiKey{} = api_key} -> {:ok, api_key}
        {:ok, nil} -> {:error, :not_found}
        {:error, _error} -> {:error, :storage_error}
      end
    else
      :error -> {:error, :not_found}
    end
  end

  defp fetch_api_key(_user, _id), do: {:error, :not_found}
end
