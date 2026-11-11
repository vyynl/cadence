defmodule Cadence.Daemon.TestHelpers do
  @moduledoc """
  Shared polling helpers for the daemon test suite.

  Tests that need to observe asynchronous work should poll a predicate with a
  bounded deadline instead of waiting a fixed number of milliseconds. A fixed
  wait is either too short (flaky on a loaded machine) or needlessly long; a
  poll makes progress as soon as the condition holds and fails with a clear
  message when it never does.

  Keep in sync with `apps/cadence_server/test/support/test_helpers.ex`.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @default_timeout 3_000
  @poll_interval 20

  @doc """
  Polls `fun` until it returns a truthy value, then returns `true`.

  Flunks after `timeout` milliseconds. Call it as
  `assert eventually(fn -> condition end)`.
  """
  def eventually(fun, timeout \\ @default_timeout) when is_function(fun, 0) do
    wait_for(fun, deadline(timeout), fn -> flunk("condition not met within #{timeout} ms") end)
  end

  @doc """
  Polls `fun` until it returns a truthy value, or `timeout` elapses.

  Always returns `:ok`. Use this for "let the queue drain / go idle" helpers
  whose old contract tolerated a timeout instead of failing the test.
  """
  def await(fun, timeout \\ @default_timeout) when is_function(fun, 0) do
    _ = wait_for(fun, deadline(timeout), fn -> :ok end)
    :ok
  end

  @doc """
  Whether `watcher`'s poll backend has exited.

  Returns `false` when the watcher is not registered, or dies while being
  inspected, so polling callers fail with their normal timeout message instead
  of an `ArgumentError` from `:sys.get_state(nil)`.
  """
  def watcher_backend_down?(watcher) do
    case GenServer.whereis(watcher) do
      nil ->
        false

      pid ->
        try do
          :sys.get_state(pid).worker == nil
        catch
          :exit, _reason -> false
        end
    end
  end

  @doc """
  Waits until a watcher's `:fs_poll` backend has published its first snapshot.

  `path` must exist before the watcher starts (write a marker into an
  otherwise empty work directory). It must not be a dotfile: the poll backend's
  `Path.wildcard/1` skips hidden entries. The polling backend's baseline
  includes the file, so seeing the path in the snapshot proves the first pass
  ran and a file written afterwards is reported as a change rather than folded
  into the baseline.

  This mirrors the GenServer state of `FileSystem.Backends.FSPoll` and
  `FileSystem.Worker`; update it when bumping `file_system`.
  """
  def await_poll_baseline(watcher, path) when is_binary(path) do
    eventually(fn -> path in poll_snapshot(watcher) end)
  end

  defp wait_for(fun, deadline, on_timeout) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        on_timeout.()
      else
        poll_pause()
        wait_for(fun, deadline, on_timeout)
      end
    end
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  # `FileSystem.Backends.FSPoll` keeps `{worker, dirs, interval, path_mtimes}`
  # in its GenServer state; the last element is the snapshot baseline.
  defp poll_snapshot(watcher) do
    try do
      with pid when is_pid(pid) <- GenServer.whereis(watcher),
           %{worker: worker} when is_pid(worker) <- :sys.get_state(pid),
           %{backend_pid: backend} when is_pid(backend) <- :sys.get_state(worker),
           {_worker, _dirs, _interval, paths} when is_map(paths) <- :sys.get_state(backend) do
        Map.keys(paths)
      else
        _ -> []
      end
    catch
      :exit, _reason -> []
    end
  end

  # A bounded poll interval. `receive` with no clauses matches nothing, so this
  # waits without consuming any message from the test process's mailbox.
  defp poll_pause do
    receive do
    after
      @poll_interval -> :ok
    end
  end
end
