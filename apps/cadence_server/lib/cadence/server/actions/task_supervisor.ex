defmodule Cadence.Server.Actions.TaskSupervisor do
  @moduledoc "Supervises one-off Docker action executions (spec §8)."

  def start_link(opts) do
    Task.Supervisor.start_link(Keyword.put(opts, :name, __MODULE__))
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end
end
