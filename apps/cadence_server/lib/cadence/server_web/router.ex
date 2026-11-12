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
    # is load-bearing for MDEx README badges; `data:` is the TOTP enrollment QR
    # (SVG data URI). Images are not a script vector.
    #
    # Only the `:browser` pipeline emits this header: unmatched-path 404 error
    # pages are rendered from the pre-pipeline conn, and `/health` and `/sync/*`
    # are not browser pages.
    plug(:put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' https: data:; font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'self'"
    })

    plug(Cadence.ServerWeb.Plugs.FetchCurrentUser)
  end

  pipeline :passkey do
    # The WebAuthn ceremony POSTs are public (sign-in) or session-guarded
    # (registration); the bound is per client IP and disabled at rate 0.
    plug(Cadence.ServerWeb.Plugs.PasskeyRateLimit)
  end

  pipeline :api do
    plug(Cadence.ServerWeb.AuthPlug)
    # After auth: the bucket is keyed on the authenticated user (spec §10.1).
    plug(Cadence.ServerWeb.Plugs.SyncRateLimit)
  end

  scope "/", Cadence.ServerWeb do
    pipe_through(:public)

    get("/health", HealthController, :index)
    get("/favicon.ico", FaviconController, :index)
  end

  # These two POSTs must be matched before `auth_routes/3` installs the
  # AshAuthentication strategy catch-all under `/auth`. They still need the
  # full browser pipeline (session, CSRF, CSP), plus the IP rate limiter.
  scope "/", Cadence.ServerWeb do
    pipe_through([:browser, :passkey])

    # Credential material must never reach access logs.
    post("/account/security/keys", PasskeyRegistrationController, :create, log: false)
    post("/auth/passkeys/sign-in", PasskeySessionController, :create, log: false)
  end

  scope "/", Cadence.ServerWeb do
    pipe_through(:browser)

    get("/", PortfolioController, :index)
    get("/proposals/:token", ProposalController, :show, log: false)
    get("/p/:slug/runs/:run_id/artifacts/*path", RunArtifactController, :show)
    get("/p/:slug/runs/:run_id/log", RunLogController, :show)

    live_session :current_user,
      on_mount: {Cadence.ServerWeb.UserAuth, :mount_current_user} do
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

    live_session :account,
      on_mount: [{Cadence.ServerWeb.UserAuth, :require_sudo_mode}] do
      live("/account", AccountLive.Settings, :index)
    end

    get("/auth/tokens/new", TokenController, :new)
    post("/auth/tokens", TokenController, :create, log: false)

    # Account security / passkey management (authenticated in every action).
    get("/account/security", AccountSecurityController, :index)
    get("/account/security/keys/new", PasskeyRegistrationController, :new)
    post("/account/security/keys/:id/rename", AccountSecurityController, :rename)
    post("/account/security/keys/:id/delete", AccountSecurityController, :delete)

    # Public passkey sign-in ceremony (the POST sets the session).
    get("/auth/passkeys/sign-in", PasskeySessionController, :new)

    # Cadence-owned sign-in and second-factor pages (spec §7.4).
    get("/sign-in", SignInController, :new)
    post("/sign-in", SignInController, :create, log: false)
    get("/sign-in/totp", TotpController, :new)
    post("/sign-in/totp", TotpController, :create, log: false)
    get("/sign-in/totp/setup", TotpSetupController, :new)
    post("/sign-in/totp/setup", TotpSetupController, :create, log: false)

    # Sign-out is a CSRF-protected POST from the header form (a GET logout
    # route would be a logout-CSRF vector).
    post("/sign-out", AuthController, :sign_out)

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
