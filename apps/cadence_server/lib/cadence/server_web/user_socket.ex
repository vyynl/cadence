defmodule Cadence.ServerWeb.UserSocket do
  @moduledoc """
  Authenticated daemon websocket.

  The API key travels in the `x-cadence-token` connect header (never the query
  string). A successful connection assigns `:current_user`; channel joins then
  authorize against that identity.
  """

  use Phoenix.Socket

  alias Cadence.Server.Accounts

  channel("sync:user:*", Cadence.ServerWeb.SyncChannel)

  @impl true
  def connect(_params, socket, connect_info) do
    with {:ok, token} <- fetch_token(connect_info),
         {:ok, user} <- Accounts.authenticate_api_key(token) do
      {:ok, assign(socket, :current_user, user)}
    else
      _ -> :error
    end
  end

  @impl true
  def id(_socket), do: nil

  defp fetch_token(connect_info) do
    connect_info
    |> Map.get(:x_headers, [])
    |> Enum.find_value(fn {name, value} ->
      if String.downcase(to_string(name)) == "x-cadence-token", do: value
    end)
    |> case do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> :error
    end
  end
end
