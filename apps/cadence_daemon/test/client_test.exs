defmodule Cadence.Daemon.ClientTest do
  use ExUnit.Case, async: true

  alias Cadence.Daemon.Client

  # Unix socket paths are limited to ~107 bytes, and `:gen_tcp.connect/4` exits
  # with `:badarg` past that, so keep these short.
  defp socket_path(label) do
    Path.join(System.tmp_dir!(), "cad-client-#{label}-#{System.unique_integer([:positive])}.sock")
  end

  test "a missing socket names the path and the reason" do
    path = socket_path("missing")

    message =
      assert_raise RuntimeError, fn ->
        Client.request("GET", "/projects", nil, path)
      end

    assert message.message =~ "unreachable at #{path}"
    assert message.message =~ ":enoent"
    assert message.message =~ "retry"
  end

  # A previous daemon leaves `daemon.sock` behind, so an early connect is
  # `:econnrefused`, not `:enoent`. Bind and close a listener to reproduce it.
  test "a socket with no listener names the path and the reason" do
    path = socket_path("stale")
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {:local, path}])
    :ok = :gen_tcp.close(listener)

    assert File.exists?(path)

    message =
      assert_raise RuntimeError, fn ->
        Client.request("GET", "/projects", nil, path)
      end

    assert message.message =~ "unreachable at #{path}"
    assert message.message =~ ":econnrefused"
  end

  test "expect! raises the same connection message" do
    path = socket_path("expect")

    message =
      assert_raise RuntimeError, fn ->
        Client.expect!("GET", "/projects", nil, path)
      end

    assert message.message =~ "unreachable at #{path}"
  end
end
