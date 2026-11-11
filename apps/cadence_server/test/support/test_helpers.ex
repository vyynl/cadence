defmodule Cadence.Server.TestHelpers do
  @moduledoc """
  Shared polling helpers for the server test suite.

  Tests that need to observe asynchronous work should poll a predicate with a
  bounded deadline instead of waiting a fixed number of milliseconds. A fixed
  wait is either too short (flaky on a loaded machine) or needlessly long; a
  poll makes progress as soon as the condition holds and fails with a clear
  message when it never does.

  Keep in sync with `apps/cadence_daemon/test/support/test_helpers.ex`. The
  daemon copy also has `await_poll_baseline/2`, which mirrors
  `FileSystem.Backends.FSPoll` + `FileSystem.Worker` GenServer state; that copy
  must be revisited when bumping `file_system`.
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

  Always returns `:ok`. Use this for "wait until idle" helpers whose old
  contract tolerated a timeout instead of failing the test.
  """
  def await(fun, timeout \\ @default_timeout) when is_function(fun, 0) do
    _ = wait_for(fun, deadline(timeout), fn -> :ok end)
    :ok
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

  # A bounded poll interval. `receive` with no clauses matches nothing, so this
  # waits without consuming any message from the test process's mailbox.
  defp poll_pause do
    receive do
    after
      @poll_interval -> :ok
    end
  end
end
