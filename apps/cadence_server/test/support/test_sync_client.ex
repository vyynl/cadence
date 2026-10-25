defmodule Cadence.ServerWeb.TestSyncClient do
  @moduledoc """
  Minimal real Slipstream client used by the server websocket integration test.
  """

  use Slipstream

  def start_link(opts) do
    Slipstream.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    socket = new_socket() |> assign(:opts, opts)

    case connect(socket, uri: opts[:uri], headers: opts[:headers]) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_connect(socket) do
    {:ok, join(socket, socket.assigns.opts[:topic])}
  end

  @impl true
  def handle_join(topic, response, socket) do
    send(socket.assigns.opts[:test_pid], {:joined, topic, response})
    {:ok, socket}
  end

  @impl true
  def handle_message(topic, event, message, socket) do
    send(socket.assigns.opts[:test_pid], {:message, topic, event, message})
    {:ok, socket}
  end
end
