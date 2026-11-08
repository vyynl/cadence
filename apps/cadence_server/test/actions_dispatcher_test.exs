defmodule Cadence.Server.Actions.DispatcherTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Cadence.Server.Actions.Dispatcher

  test "the enabled boot pass calls dispatch once and exits :normal" do
    parent = self()

    dispatch = fn ->
      send(parent, :dispatched)

      receive do
        :release -> :ok
      end
    end

    name = :"dispatcher_#{System.unique_integer([:positive])}"

    {:ok, pid} = Dispatcher.start_link(name: name, enabled: true, dispatch: dispatch)
    assert_receive :dispatched, 1_000

    ref = Process.monitor(pid)
    send(pid, :release)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end

  test "a disabled boot pass starts nothing" do
    assert Dispatcher.start_link(enabled: false) == :ignore
  end

  test "a crashing dispatch is logged by shape and does not crash the process" do
    parent = self()

    dispatch = fn ->
      send(parent, :dispatched)

      receive do
        :release -> raise "boom"
      end
    end

    name = :"dispatcher_#{System.unique_integer([:positive])}"

    log =
      capture_log(fn ->
        {:ok, pid} = Dispatcher.start_link(name: name, enabled: true, dispatch: dispatch)
        assert_receive :dispatched, 1_000

        ref = Process.monitor(pid)
        send(pid, :release)

        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
      end)

    assert log =~ "action run boot dispatch skipped"
    refute log =~ "boom"
  end
end
