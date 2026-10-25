defmodule Cadence.Daemon.EnvTest do
  use ExUnit.Case, async: false

  alias Cadence.Daemon.Env

  test "sync defaults are local-first" do
    assert Env.sync_enabled?()
    assert Env.sync_channel_enabled?()
    assert Env.sync_request_timeout_ms() == 5_000
    assert Env.sync_interval_ms() == 30_000
    assert Env.sync_retry_backoff_ms() == 30_000
    assert Env.sync_max_attempts() == 10
    assert Env.sync_push_limit() == 100
    assert Env.sync_req_options() == []
    assert Env.server_url() == nil
    assert Env.sync_socket_url() == nil
    assert Env.auth_token() == nil
  end

  test "derives the websocket URL from the server URL" do
    on_exit(fn -> Application.delete_env(:cadence_daemon, :server_url) end)

    Application.put_env(:cadence_daemon, :server_url, "http://localhost:4000")
    assert Env.sync_socket_url() == "ws://localhost:4000/socket/websocket"

    Application.put_env(:cadence_daemon, :server_url, "https://cadence.example/")
    assert Env.sync_socket_url() == "wss://cadence.example/socket/websocket"
  end

  test "the channel can be disabled independently" do
    on_exit(fn -> Application.delete_env(:cadence_daemon, :sync_channel_enabled) end)

    Application.put_env(:cadence_daemon, :sync_channel_enabled, false)
    refute Env.sync_channel_enabled?()
  end
end
