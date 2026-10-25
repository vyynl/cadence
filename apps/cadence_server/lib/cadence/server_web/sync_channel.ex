defmodule Cadence.ServerWeb.SyncChannel do
  @moduledoc """
  Notification-only channel for a user's daemons (spec §10.5).

  The channel carries no DAG or preference state; it only forwards
  `sync_available` hints so a daemon can wake its HTTP sync worker early.
  """

  use Phoenix.Channel

  @impl true
  def join("sync:user:" <> user_id, _payload, socket) do
    if user_id == socket.assigns.current_user.id do
      Phoenix.PubSub.subscribe(Cadence.Server.PubSub, "sync:user:#{user_id}")
      {:ok, socket}
    else
      {:error, %{reason: "forbidden"}}
    end
  end

  @impl true
  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:sync_available, project_id}, socket) do
    push(socket, "sync_available", %{project_id: project_id})
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}
end
