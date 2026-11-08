defmodule Cadence.Server.Actions.Retention do
  @moduledoc """
  Periodic backstop for `Cadence.Server.Actions.Cleanup` (spec §8.3).

  The manual entry point is `mix cadence.actions_sweep`; this process makes the
  policy apply without an operator. It runs one pass every
  `CAD_ACTIONS_RETENTION_INTERVAL_MS` (default 6 h); `0` disables the backstop
  (the test default). The sweep function is injectable through
  `:actions_cleanup`, the same pattern as `:actions_docker` and the repacker, so
  the process is testable without touching disk or Docker.
  """

  use GenServer

  require Logger

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    state = %{
      runner: Keyword.get(opts, :runner, cleanup_fun()),
      enabled: Keyword.get(opts, :enabled, Cadence.Server.Actions.enabled?()),
      interval_ms: Keyword.get(opts, :interval_ms, Cadence.Server.Actions.retention_interval_ms())
    }

    {:ok, if(state.enabled, do: schedule(state), else: state)}
  end

  @impl true
  def handle_info(:sweep, state) do
    try do
      state.runner.()
    rescue
      error -> Logger.warning("action retention skipped: #{shape(error)}")
    catch
      kind, reason ->
        Logger.warning("action retention exited: #{inspect(kind)}/#{shape(reason)}")
    end

    {:noreply, schedule(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule(%{interval_ms: interval} = state)
       when is_integer(interval) and interval > 0 do
    Process.send_after(self(), :sweep, interval)
    state
  end

  defp schedule(state), do: state

  defp cleanup_fun do
    Application.get_env(
      :cadence_server,
      :actions_cleanup,
      &Cadence.Server.Actions.Cleanup.run/0
    )
  end

  # Never log raw terms from a crashed sweep.
  defp shape(%{__struct__: module}), do: inspect(module)
  defp shape(term) when is_atom(term), do: Atom.to_string(term)
  defp shape(term) when is_tuple(term), do: "tuple/#{tuple_size(term)}"
  defp shape(_term), do: "term"
end
