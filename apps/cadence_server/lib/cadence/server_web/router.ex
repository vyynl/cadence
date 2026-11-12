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

    # This must stay a literal map with the lowercase "content-security-policy"
    # key: any indirection (function call, variable, interpolation) downgrades
    # Sobelow's Config.CSP check to :low, which still passes `--exit medium`, and
    # a capitalized key emits two headers.
    #
    # `style-src 'unsafe-inline'` is required for the DAG layout and stagger
    # style attributes (nonces cannot cover style attributes). `img-src https:`
    # is load-bearing for MDEx README badges and for the AshAuth sign-in page's
    # banner image; images are not a script vector.
    #
    # Only the `:browser` pipeline emits this header: unmatched-path 404 error
    # pages are rendered from the pre-pipeline conn, and `/health` and `/sync/*`
    # are not browser pages.
    plug(:put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' https:; font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'self'"
    })

    plug(:load_from_session)
  end

  pipeline :api do
    plug(Cadence.ServerWeb.AuthPlug)
    # After auth: the bucket is keyed on the authenticated user (spec §10.1).
    plug(Cadence.ServerWeb.Plugs.SyncRateLimit)
  end

  scope "/", Cadence.ServerWeb do
    pipe_through(:public)

    get("/health", HealthController, :index)
  end

  scope "/", Cadence.ServerWeb do
    pipe_through(:browser)

    get("/", PortfolioController, :index)
    get("/proposals/:token", ProposalController, :show, log: false)
    get("/p/:slug/runs/:run_id/artifacts/*path", RunArtifactController, :show)
    get("/p/:slug/runs/:run_id/log", RunLogController, :show)

    ash_authentication_live_session :project do
      live("/p/:slug", ProjectLive, :home)
      live("/p/:slug/history", HistoryLive.Index, :index)
      live("/p/:slug/n/:node_id", ProjectLive, :node)
      live("/p/:slug/n/:node_id/tree", ProjectLive, :tree)
      live("/p/:slug/n/:node_id/tree/*path", ProjectLive, :tree)
      live("/p/:slug/n/:node_id/blob/*path", ProjectLive, :blob)
      live("/p/:slug/reviews", ReviewLive.Index, :index)
      live("/p/:slug/reviews/:proposal_id", ReviewLive.Show, :show)
      live("/p/:slug/runs", RunLive.Index, :index)
      live("/p/:slug/runs/:run_id", RunLive.Show, :show)
    end

    get("/auth/tokens/new", TokenController, :new)
    post("/auth/tokens", TokenController, :create, log: false)

    sign_in_route(auth_routes_prefix: "/auth", layout: {Cadence.ServerWeb.Layouts, :app})
    sign_out_route(AuthController, "/sign-out", layout: {Cadence.ServerWeb.Layouts, :app})

    auth_routes(AuthController, Cadence.Server.Accounts.User, path: "/auth")
  end

  scope "/", Cadence.ServerWeb do
    pipe_through(:api)

    post("/sync/nodes", SyncController, :push_nodes)
    get("/sync/nodes", SyncController, :pull_nodes)
    post("/sync/objects/exists", SyncController, :objects_exist)
    post("/sync/projects", SyncController, :provision_project)
    post("/sync/preferences", SyncController, :push_preferences)
    post("/sync/union", SyncController, :union)
    get("/sync/me", SyncController, :me)
  end
end
