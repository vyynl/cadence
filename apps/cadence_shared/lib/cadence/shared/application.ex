defmodule Cadence.Shared.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [Cadence.Shared.GitStore.Cache]

    Supervisor.start_link(children, strategy: :one_for_one, name: Cadence.Shared.Supervisor)
  end
end
