defmodule Cadence.Daemon.SyncSocketTest do
  use Slipstream.SocketTest, async: false

  import Ecto.Query

  alias Cadence.Daemon.{Repo, SyncLedger, SyncSocket, SyncState}
  alias Cadence.Shared.Project

  @user_id "22222222-2222-4222-8222-222222222222"
  @topic "sync:user:#{@user_id}"

  setup do
    clear_sync_config()
    clear_server_user()

    on_exit(fn ->
      clear_server_user()
      clear_sync_config()
    end)

    :ok
  end

  test "connects and joins the user topic" do
    put_server_user()
    client = start_socket()

    accept_connect(client)
    assert_join(@topic, %{}, :ok)
  end

  test "waits for the server user ID before joining" do
    client = start_socket(join_retry_ms: 10)

    accept_connect(client)
    refute_join(@topic, %{}, 50)

    put_server_user()
    assert_join(@topic, %{}, :ok)
  end

  test "wakes the local project when sync_available arrives" do
    project = insert_project()
    put_server_user()
    test_pid = self()

    client =
      start_socket(waker: fn project_id -> send(test_pid, {:wake, project_id}) end)

    accept_connect(client)
    assert_join(@topic, %{}, :ok)

    push(client, @topic, "sync_available", %{"project_id" => project.id})

    assert_receive {:wake, project_id}
    assert project_id == project.id
  end

  test "ignores sync_available for unknown projects" do
    put_server_user()
    test_pid = self()

    client =
      start_socket(waker: fn project_id -> send(test_pid, {:wake, project_id}) end)

    accept_connect(client)
    assert_join(@topic, %{}, :ok)

    push(client, @topic, "sync_available", %{"project_id" => Ecto.UUID.generate()})

    refute_receive {:wake, _project_id}, 50
  end

  test "reconnects and rejoins after a disconnect" do
    put_server_user()
    client = start_socket()

    accept_connect(client)
    assert_join(@topic, %{}, :ok)

    disconnect(client, :closed_by_test)
    accept_connect(client)
    assert_join(@topic, %{}, :ok)
  end

  test "is disabled when sync is not configured" do
    assert :ignore = SyncSocket.start_link([])
  end

  defp start_socket(opts \\ []) do
    opts =
      Keyword.merge(
        [
          uri: "ws://localhost:4000/socket/websocket",
          headers: [{"x-cadence-token", "test-token"}],
          test_mode?: true
        ],
        opts
      )

    start_supervised!({SyncSocket, opts})
  end

  defp put_server_user do
    {:ok, _user_id} = SyncLedger.put_server_user_id(@user_id)
  end

  defp insert_project do
    %{
      name: "socket",
      slug: "socket-#{System.unique_integer([:positive])}",
      owner_id: Ecto.UUID.generate()
    }
    |> Project.changeset()
    |> Repo.insert!()
  end

  defp clear_server_user do
    Repo.delete_all(from(s in SyncState, where: s.key == "server_user_id"))
  end

  defp clear_sync_config do
    Enum.each(
      [:server_url, :auth_token, :sync_enabled, :sync_channel_enabled, :sync_req_options],
      &Application.delete_env(:cadence_daemon, &1)
    )
  end
end
