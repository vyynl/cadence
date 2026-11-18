defmodule Cadence.Daemon.TUI.FakeClient do
  @moduledoc """
  Test double for `Cadence.Daemon.TUI.Client`.

  The TUI takes the client as a module and forwards `:fake` in its client
  options, so each test starts an `Agent` holding the canned responses and
  passes it as `fake: agent`. Every call is also reported to the test process
  as `{:fake_call, name, args}` so a test can assert the arguments a key press
  produced.

  A response value may be a term or a one-arity function (useful when the same
  endpoint should answer differently per node).
  """

  def health(opts), do: perform(opts, :health, [])
  def projects(opts), do: perform(opts, :projects, [])
  def graph(project_id, opts), do: perform(opts, :graph, [project_id])
  def diff(project_id, node_id, opts), do: perform(opts, :diff, [project_id, node_id])
  def switch(project_id, node_id, opts), do: perform(opts, :switch, [project_id, node_id])
  def spawn(project_id, name, opts), do: perform(opts, :spawn, [project_id, name])
  def union(project_id, ids, opts), do: perform(opts, :union, [project_id, ids])
  def proposals(project_id, opts), do: perform(opts, :proposals, [project_id])
  def docs_sync(project_id, node_id, opts), do: perform(opts, :docs_sync, [project_id, node_id])
  def docs_diff(project_id, node_id, opts), do: perform(opts, :docs_diff, [project_id, node_id])

  defp perform(opts, name, args) do
    agent = Keyword.fetch!(opts, :fake)

    state =
      Agent.get_and_update(agent, fn state ->
        state = Map.update(state, :calls, [{name, args}], &[{name, args} | &1])
        {state, state}
      end)

    if pid = state[:notify] do
      send(pid, {:fake_call, name, args})
    end

    case Map.get(state, name, {:ok, %{}}) do
      fun when is_function(fun, 1) -> fun.(args)
      value -> value
    end
  end
end
