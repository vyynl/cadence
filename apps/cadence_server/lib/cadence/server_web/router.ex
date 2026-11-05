defmodule Cadence.ServerWeb.Router do
  @moduledoc """
  Server HTTP routes: health, OAuth/token issuance, and the sync API.
  """

  use Cadence.ServerWeb, :router
  use AshAuthentication.Phoenix.Router

  pipeline :public do
  end

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_flash)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(:load_from_session)
  end

  pipeline :api do
    plug(Cadence.ServerWeb.AuthPlug)
  end

  scope "/", Cadence.ServerWeb do
    pipe_through(:public)

    get("/health", HealthController, :index)
  end

  scope "/", Cadence.ServerWeb do
    pipe_through(:browser)

    get("/", PortfolioController, :index)
    get("/proposals/:token", ProposalController, :show, log: false)

    ash_authentication_live_session :project do
      live("/p/:slug", ProjectLive, :home)
      live("/p/:slug/n/:node_id", ProjectLive, :node)
      live("/p/:slug/n/:node_id/tree", ProjectLive, :tree)
      live("/p/:slug/n/:node_id/tree/*path", ProjectLive, :tree)
      live("/p/:slug/n/:node_id/blob/*path", ProjectLive, :blob)
      live("/p/:slug/reviews", ReviewLive.Index, :index)
      live("/p/:slug/reviews/:proposal_id", ReviewLive.Show, :show)
    end

    get("/auth/tokens/new", TokenController, :new)
    post("/auth/tokens", TokenController, :create)

    auth_routes(AuthController, Cadence.Server.Accounts.User, path: "/auth")
  end

  scope "/", Cadence.ServerWeb do
    pipe_through(:api)

    post("/sync/nodes", SyncController, :push_nodes)
    get("/sync/nodes", SyncController, :pull_nodes)
    post("/sync/projects", SyncController, :provision_project)
    post("/sync/preferences", SyncController, :push_preferences)
    get("/sync/me", SyncController, :me)
  end
end
