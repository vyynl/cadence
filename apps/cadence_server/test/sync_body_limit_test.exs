defmodule Cadence.ServerWeb.SyncBodyLimitTest do
  use Cadence.ServerWeb.ConnCase, async: false

  import Phoenix.ConnTest

  @default_sync_max_body_bytes 64 * 1024 * 1024

  setup do
    previous = Application.get_env(:cadence_server, :sync_max_body_bytes)
    on_exit(fn -> restore_env(previous) end)
    :ok
  end

  test "rejects a sync body over the configured limit before authentication", %{conn: conn} do
    Application.put_env(:cadence_server, :sync_max_body_bytes, 1_024)

    body = Jason.encode!(%{"nodes" => [%{"pad" => String.duplicate("a", 2_048)}]})

    # ConnTest re-raises parser errors; the adapter (Bandit in production) maps
    # them with `Plug.Exception.status/1`, which is 413 for this exception.
    error =
      assert_raise Plug.Parsers.RequestTooLargeError, fn ->
        conn
        |> json_conn()
        |> post("/sync/nodes", body)
      end

    assert Plug.Exception.status(error) == 413
  end

  test "accepts a sync body exactly at the limit", %{conn: conn} do
    body = Jason.encode!(%{"nodes" => [%{"pad" => String.duplicate("a", 128)}]})
    Application.put_env(:cadence_server, :sync_max_body_bytes, byte_size(body))

    response =
      conn
      |> json_conn()
      |> post("/sync/nodes", body)

    # Parsed, then rejected by the auth plug: the exact boundary is not 413.
    assert response.status == 401
  end

  test "browser and public routes keep the default parser limit", %{conn: conn} do
    Application.put_env(:cadence_server, :sync_max_body_bytes, 16)

    body = "name=" <> String.duplicate("a", 512)

    response =
      conn
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> post("/auth/tokens", body)

    refute response.status == 413
  end

  test "an absent, non-positive, or non-integer limit falls back to the default" do
    for value <- [nil, 0, -1, "nope"] do
      Application.put_env(:cadence_server, :sync_max_body_bytes, value)

      assert Cadence.ServerWeb.Parsers.sync_max_body_bytes() == @default_sync_max_body_bytes
    end
  end

  defp json_conn(conn) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
  end

  defp restore_env(nil), do: Application.delete_env(:cadence_server, :sync_max_body_bytes)
  defp restore_env(value), do: Application.put_env(:cadence_server, :sync_max_body_bytes, value)
end
