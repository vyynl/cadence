defmodule Cadence.Server.Actions.Dispatcher do
  @moduledoc """
  One-shot boot pass that drains queued action runs (spec §8.3).

  A `:queued` row is durable waiting work: if the server restarts while runs are
  waiting (or dies between writing a row and dispatching it), nothing else would
  start them. This process calls `Runs.dispatch_all/0` once after boot and exits
  `:normal`, so it leaves no idle process behind. The child spec is temporary:
  the normal exit is not restarted.

  Disabled through `CAD_ACTIONS_DISPATCH_ON_BOOT=false`; tests disable it
  because a boot process must not query the sandboxed Repo. The dispatch
  function is injectable through `:actions_dispatcher` so the process itself is
  testable without a database.
  """

  use GenServer

  require Logger

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  @impl true
  def init(opts) do
    if Keyword.get(opts, :enabled, enabled?()) do
      send(self(), {:dispatch, Keyword.get(opts, :dispatch, dispatch_fun())})
      {:ok, %{}}
    else
      :ignore
    end
  end

  @impl true
  def handle_info({:dispatch, dispatch}, state) do
    try do
      dispatch.()
    rescue
      error -> Logger.warning("action run boot dispatch skipped: #{shape(error)}")
    catch
      kind, reason ->
        Logger.warning("action run boot dispatch exited: #{inspect(kind)}/#{shape(reason)}")
    end

    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp enabled? do
    Cadence.Server.Actions.dispatch_on_boot?() and Cadence.Server.Actions.enabled?()
  end

  defp dispatch_fun do
    Application.get_env(
      :cadence_server,
      :actions_dispatcher,
      &Cadence.Server.Actions.Runs.dispatch_all/0
    )
  end

  # Never log raw terms from a crashed dispatch.
  defp shape(%{__struct__: module}), do: inspect(module)
  defp shape(term) when is_atom(term), do: Atom.to_string(term)
  defp shape(term) when is_tuple(term), do: "tuple/#{tuple_size(term)}"
  defp shape(_term), do: "term"
end
