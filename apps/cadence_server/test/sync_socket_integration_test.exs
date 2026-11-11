defmodule Cadence.ServerWeb.SyncSocketIntegrationTest do
  use ExUnit.Case, async: false

  alias Cadence.Server.{Accounts, Repo}
  alias Cadence.Server.Accounts.User
  alias Cadence.ServerWeb.{TestSocketEndpoint, TestSyncClient}

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    user =
      Ash.Seed.seed!(User, %{
        email: "socket-integration-#{System.unique_integer([:positive])}@example.com"
      })

    {:ok, api_key} = Accounts.create_api_key(user, "socket-integration")
    port = free_port()

    Application.put_env(:cadence_server, TestSocketEndpoint,
      server: true,
      adapter: Bandit.PhoenixAdapter,
      http: [ip: {127, 0, 0, 1}, port: port],
      secret_key_base: String.duplicate("test-secret-key-base-", 4),
      pubsub_server: Cadence.Server.PubSub,
      check_origin: false
    )

    start_supervised!(TestSocketEndpoint)
    wait_for_port(port)

    on_exit(fn -> Application.delete_env(:cadence_server, TestSocketEndpoint) end)

    %{user: user, plaintext: api_key.__metadata__.plaintext_api_key, port: port}
  end

  test "a real client connects, joins, and receives sync_available", %{
    user: user,
    plaintext: plaintext,
    port: port
  } do
    topic = "sync:user:#{user.id}"
    project_id = Ecto.UUID.generate()

    start_supervised!(
      {TestSyncClient,
       [
         uri: "ws://127.0.0.1:#{port}/socket/websocket",
         headers: [{"x-cadence-token", plaintext}],
         topic: topic,
         test_pid: self()
       ]}
    )

    assert_receive {:joined, ^topic, _response}, 5_000

    Phoenix.PubSub.broadcast(Cadence.Server.PubSub, topic, {:sync_available, project_id})

    assert_receive {:message, ^topic, "sync_available", %{"project_id" => ^project_id}}, 5_000
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp wait_for_port(port) do
    Cadence.Server.TestHelpers.eventually(fn -> port_open?(port) end)
  end

  defp port_open?(port) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 100) do
      {:ok, socket} ->
        :ok = :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end
end
