defmodule Cadence.Daemon.ReleaseConnectionTest do
  @moduledoc """
  `Release.check_connection/0` is what the image's `setup` calls to verify the
  server URL and token while the operator is still at the prompt (spec §12.8).
  """

  use ExUnit.Case, async: false

  alias Cadence.Daemon.Release

  @keys [:server_url, :auth_token, :sync_req_options]

  setup do
    saved = Map.new(@keys, &{&1, Application.get_env(:cadence_daemon, &1)})

    on_exit(fn ->
      Enum.each(@keys, fn key ->
        case Map.fetch!(saved, key) do
          nil -> Application.delete_env(:cadence_daemon, key)
          value -> Application.put_env(:cadence_daemon, key, value)
        end
      end)
    end)

    :ok
  end

  defp configure do
    Application.put_env(:cadence_daemon, :server_url, "http://server.test")
    Application.put_env(:cadence_daemon, :auth_token, "cad-token")
    Application.put_env(:cadence_daemon, :sync_req_options, plug: {Req.Test, __MODULE__})
  end

  test "reports missing configuration instead of raising" do
    Application.delete_env(:cadence_daemon, :server_url)
    Application.delete_env(:cadence_daemon, :auth_token)

    assert Release.check_connection() == {:error, :not_configured}
  end

  test "is ok when the server accepts the token" do
    configure()

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"user_id":"a-user"}))
    end)

    assert Release.check_connection() == :ok
  end

  test "reports a rejected token" do
    configure()

    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 401, ~s({"error":"unauthorized"}))
    end)

    assert Release.check_connection() == {:error, :unauthorized}
  end

  test "reports other statuses and transport failures" do
    configure()

    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)

    assert Release.check_connection() == {:error, {:http, 503}}

    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    assert Release.check_connection() == {:error, :unreachable}
  end
end
