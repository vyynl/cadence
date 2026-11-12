defmodule Cadence.Server.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Cadence.Server.Repo,
      {AshAuthentication.Supervisor, otp_app: :cadence_server},
      {Phoenix.PubSub, name: Cadence.Server.PubSub},
      Cadence.Server.LLMRateLimit,
      Cadence.Server.SyncRateLimit,
      Cadence.Server.PasskeyRateLimit,
      Cadence.Server.MeldWorker,
      Cadence.Server.Actions.TaskSupervisor,
      Cadence.Server.Actions.Dispatcher,
      Cadence.Server.Actions.Retention,
      Cadence.Server.Storage.TaskSupervisor,
      Cadence.Server.Storage.Repacker,
      Cadence.Server.ProposalCache,
      Cadence.ServerWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Cadence.Server.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
