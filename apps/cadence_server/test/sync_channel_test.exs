defmodule Cadence.ServerWeb.SyncChannelTest do
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest

  alias Cadence.Server.{Accounts, Repo}
  alias Cadence.Server.Accounts.User
  alias Cadence.ServerWeb.{SyncChannel, UserSocket}

  @endpoint Cadence.ServerWeb.Endpoint

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    user =
      Ash.Seed.seed!(User, %{email: "channel-#{System.unique_integer([:positive])}@example.com"})

    {:ok, api_key} = Accounts.create_api_key(user, "channel-test")

    %{user: user, plaintext: api_key.__metadata__.plaintext_api_key}
  end

  test "connects with an API key header and joins the user topic", %{
    user: user,
    plaintext: plaintext
  } do
    assert {:ok, socket} =
             connect(UserSocket, %{},
               connect_info: %{x_headers: [{"x-cadence-token", plaintext}]}
             )

    assert socket.assigns.current_user.id == user.id

    assert {:ok, _reply, _socket} =
             subscribe_and_join(socket, SyncChannel, "sync:user:#{user.id}")

    project_id = Ecto.UUID.generate()

    Phoenix.PubSub.broadcast(
      Cadence.Server.PubSub,
      "sync:user:#{user.id}",
      {:sync_available, project_id}
    )

    assert_push("sync_available", %{project_id: ^project_id})
  end

  test "accepts a case-insensitive header name", %{plaintext: plaintext} do
    assert {:ok, _socket} =
             connect(UserSocket, %{},
               connect_info: %{x_headers: [{"X-Cadence-Token", plaintext}]}
             )
  end

  test "rejects missing, invalid, and query-string tokens", %{plaintext: plaintext} do
    assert :error = connect(UserSocket, %{}, connect_info: %{x_headers: []})

    assert :error =
             connect(UserSocket, %{},
               connect_info: %{x_headers: [{"x-cadence-token", "cad_not_a_real_key"}]}
             )

    assert :error =
             connect(UserSocket, %{"token" => plaintext}, connect_info: %{x_headers: []})

    assert :error = connect(UserSocket, %{"x-cadence-token" => plaintext}, connect_info: %{})
  end

  test "cannot join another user's topic", %{user: user, plaintext: plaintext} do
    assert {:ok, socket} =
             connect(UserSocket, %{},
               connect_info: %{x_headers: [{"x-cadence-token", plaintext}]}
             )

    assert {:error, %{reason: "forbidden"}} =
             join(socket, SyncChannel, "sync:user:#{Ecto.UUID.generate()}")

    assert {:ok, _reply, _socket} = join(socket, SyncChannel, "sync:user:#{user.id}")
  end
end
