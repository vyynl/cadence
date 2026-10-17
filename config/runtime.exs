import Config

if config_env() != :test do
  state_dir =
    System.get_env("CAD_STATE_DIR", Path.join(System.user_home!(), ".local/state/cadence"))

  config :cadence_daemon, Cadence.Daemon.Repo, database: Path.join(state_dir, "cadence.db")

  config :cadence_daemon,
    ignore:
      System.get_env(
        "CAD_IGNORE",
        "_build,deps,node_modules,.venv,venv,__pycache__,.elixir_ls,target"
      )
      |> String.split(",", trim: true)

  config :cadence_daemon,
    watch_debounce_ms: String.to_integer(System.get_env("CAD_WATCH_DEBOUNCE_MS", "2000")),
    watch_backend:
      (case System.get_env("CAD_WATCH_BACKEND", "fs_inotify") do
         "fs_poll" -> :fs_poll
         _ -> :fs_inotify
       end),
    local_user_id: System.get_env("CAD_LOCAL_USER_ID", "00000000-0000-0000-0000-000000000000")

  config :cadence_daemon,
    llm_timeout_ms: String.to_integer(System.get_env("CAD_LLM_TIMEOUT_MS", "5000")),
    llm_rate_limit: String.to_integer(System.get_env("CAD_LLM_RATE_LIMIT", "10")),
    llm_rate_scale: String.to_integer(System.get_env("CAD_LLM_RATE_SCALE", "60000")),
    llm_diff_max_bytes: String.to_integer(System.get_env("CAD_LLM_DIFF_MAX_BYTES", "32768")),
    llm_retry_attempts: String.to_integer(System.get_env("CAD_LLM_RETRY_ATTEMPTS", "3")),
    llm_retry_initial_ms: String.to_integer(System.get_env("CAD_LLM_RETRY_INITIAL_MS", "0")),
    llm_retry_backoff_ms: String.to_integer(System.get_env("CAD_LLM_RETRY_BACKOFF_MS", "5000"))

  config :cadence_daemon,
    diff_max_files: String.to_integer(System.get_env("CAD_DIFF_MAX_FILES", "20")),
    diff_max_lines_per_file:
      String.to_integer(System.get_env("CAD_DIFF_MAX_LINES_PER_FILE", "400"))

  # -- Server ---------------------------------------------------------------

  listen_port = String.to_integer(System.get_env("CAD_HTTP_PORT", "4000"))

  database_url =
    case {config_env(), System.get_env("CAD_DATABASE_URL")} do
      {:prod, nil} -> System.fetch_env!("CAD_DATABASE_URL")
      {_, nil} -> "ecto://postgres:postgres@localhost:5432/cadence_dev"
      {_, url} -> url
    end

  secret_key_base = System.fetch_env!("CAD_SECRET_KEY_BASE")

  public_url =
    case {config_env(), System.get_env("CAD_PUBLIC_URL")} do
      {:prod, nil} -> System.fetch_env!("CAD_PUBLIC_URL")
      {_, nil} -> "http://localhost:#{listen_port}"
      {_, url} -> url
    end
    |> String.trim_trailing("/")

  public_uri = URI.parse(public_url)
  phx_host = System.get_env("CAD_PHX_HOST") || public_uri.host

  config :cadence_server, Cadence.Server.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("CAD_DB_POOL_SIZE", "10"))

  config :cadence_server, Cadence.ServerWeb.Endpoint,
    server: true,
    http: [ip: {0, 0, 0, 0}, port: listen_port],
    url: [
      host: phx_host,
      port: public_uri.port,
      scheme: public_uri.scheme
    ],
    secret_key_base: secret_key_base

  git_store_path =
    System.get_env(
      "CAD_GIT_STORE_PATH",
      if(config_env() == :prod,
        do: "/data/git",
        else: Path.join(System.user_home!(), ".local/state/cadence/server-git")
      )
    )

  config :cadence_server,
    public_url: public_url,
    token_signing_secret: System.get_env("CAD_TOKEN_SIGNING_SECRET") || secret_key_base,
    git_store_path: git_store_path,
    sync_pull_limit: String.to_integer(System.get_env("CAD_SYNC_PULL_LIMIT", "100")),
    oauth: [
      github: [
        client_id: System.get_env("CAD_OAUTH_GITHUB_CLIENT_ID"),
        client_secret: System.get_env("CAD_OAUTH_GITHUB_CLIENT_SECRET"),
        redirect_uri: public_url <> "/auth/user/github/callback"
      ],
      google: [
        client_id: System.get_env("CAD_OAUTH_GOOGLE_CLIENT_ID"),
        client_secret: System.get_env("CAD_OAUTH_GOOGLE_CLIENT_SECRET"),
        redirect_uri: public_url <> "/auth/user/google/callback"
      ]
    ]
end

config :cadence_shared, Cadence.Shared.LLM,
  provider: System.get_env("CAD_LLM_PROVIDER", "deepseek"),
  api_key: System.get_env("CAD_LLM_API_KEY"),
  model: System.get_env("CAD_LLM_MODEL", "deepseek-chat"),
  base_url: System.get_env("CAD_LLM_BASE_URL", "https://api.deepseek.com")
