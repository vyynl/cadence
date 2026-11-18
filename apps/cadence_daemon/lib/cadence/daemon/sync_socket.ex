defmodule Cadence.Daemon.SyncSocket do
  @moduledoc """
  Optional Phoenix Channels client for sync notifications (spec §10.5).

  The socket carries only `sync_available` hints. It never transfers DAG or
  preference state; HTTP polling in `Cadence.Daemon.SyncWorker` remains the
  correctness path. The process is skipped entirely when sync or the channel is
  disabled, or when no server credentials are configured.
  """

  use Slipstream

  require Logger

  alias Cadence.Daemon.{Env, Projects, SyncClient, SyncLedger, SyncWorker}
  alias Cadence.Shared.UUID

  @join_retry_ms 1_000

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    if name do
      Slipstream.start_link(__MODULE__, opts, name: name)
    else
      Slipstream.start_link(__MODULE__, opts)
    end
  end

  @impl true
  def init(opts) do
    opts = Keyword.merge([join_retry_ms: @join_retry_ms, waker: &SyncWorker.wake/1], opts)

    if connect_enabled?(opts) do
      socket = new_socket() |> assign(:opts, opts)

      case connect(socket, connection_config(opts)) do
        {:ok, socket} ->
          {:ok, socket}

        {:error, reason} ->
          Logger.error("sync socket could not start: #{inspect(reason)}")
          :ignore
      end
    else
      :ignore
    end
  end

  @impl true
  def handle_connect(socket) do
    case SyncLedger.server_user_id() do
      nil -> {:ok, schedule_join(socket)}
      user_id -> {:ok, join(socket, user_topic(user_id))}
    end
  end

  @impl true
  def handle_join(_topic, _response, socket) do
    {:ok, cancel_join_retry(socket)}
  end

  @impl true
  def handle_info(:join_retry, socket) do
    socket = assign(socket, :join_retry_timer, nil)

    case SyncLedger.server_user_id() do
      nil -> {:noreply, schedule_join(socket)}
      user_id -> {:noreply, join(socket, user_topic(user_id))}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_message(_topic, "sync_available", %{"project_id" => project_id}, socket) do
    wake(socket, project_id)
    {:ok, socket}
  end

  def handle_message(_topic, _event, _message, socket), do: {:ok, socket}

  defp connect_enabled?(opts) do
    Keyword.has_key?(opts, :uri) or
      (Env.sync_enabled?() and Env.sync_channel_enabled?() and SyncClient.configured?())
  end

  defp connection_config(opts) do
    uri = opts[:uri] || Env.sync_socket_url()
    headers = opts[:headers] || [{"x-cadence-token", Env.auth_token() || ""}]

    config =
      [uri: uri, headers: headers, mint_opts: mint_opts()]
      |> maybe_test_mode(opts)
      |> Keyword.merge(
        Keyword.take(opts, [:reconnect_after_msec, :rejoin_after_msec, :heartbeat_interval_msec])
      )

    config
  end

  # Same trust configuration as `SyncClient`: Slipstream hands `mint_opts` to
  # `Mint.HTTP.connect/4`, where the same `transport_opts` apply.
  defp mint_opts do
    [protocols: [:http1], transport_opts: Env.sync_transport_opts()]
  end

  defp maybe_test_mode(config, opts) do
    if opts[:test_mode?], do: Keyword.put(config, :test_mode?, true), else: config
  end

  defp user_topic(user_id), do: "sync:user:#{user_id}"

  defp schedule_join(socket) do
    if socket.assigns[:join_retry_timer] do
      socket
    else
      timer = Process.send_after(self(), :join_retry, socket.assigns.opts[:join_retry_ms])
      assign(socket, :join_retry_timer, timer)
    end
  end

  defp cancel_join_retry(socket) do
    case socket.assigns[:join_retry_timer] do
      nil ->
        socket

      timer ->
        Process.cancel_timer(timer)
        assign(socket, :join_retry_timer, nil)
    end
  end

  defp wake(socket, project_id) do
    with {:ok, project_id} <- UUID.cast(project_id),
         %{} <- Projects.get_project(project_id) do
      socket.assigns.opts[:waker].(project_id)
    else
      _ -> Logger.debug("ignoring sync_available for unknown project #{inspect(project_id)}")
    end
  end
end
