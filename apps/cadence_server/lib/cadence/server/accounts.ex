defmodule Cadence.Server.Accounts do
  @moduledoc """
  Server-side accounts: OAuth identities and daemon API keys.

  Human users authenticate with GitHub or Google; daemons authenticate with
  personal access tokens modelled as AshAuthentication API keys (spec §7.4,
  §10.1).
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
end
