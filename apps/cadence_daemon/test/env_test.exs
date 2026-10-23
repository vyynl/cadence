defmodule Cadence.Daemon.EnvTest do
  use ExUnit.Case, async: false

  alias Cadence.Daemon.Env

  test "sync defaults are local-first" do
    assert Env.sync_enabled?()
    assert Env.sync_request_timeout_ms() == 5_000
    assert Env.sync_interval_ms() == 30_000
    assert Env.sync_retry_backoff_ms() == 30_000
    assert Env.sync_max_attempts() == 10
    assert Env.sync_push_limit() == 100
    assert Env.sync_req_options() == []
    assert Env.server_url() == nil
    assert Env.auth_token() == nil
  end
end
