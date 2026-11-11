import Config

# This file is evaluated by every artifact built from the umbrella. The daemon
# release (spec §12.8) contains only `cadence_daemon` + `cadence_shared`, so the
# server block below — which requires the server's prod-only variables — is
# evaluated only when `cadence_server` is on this artifact's code path. Dev/test
# checkouts and the `cadence` server release include it; `mix release
# cadence_daemon` does not.
server_artifact? = not match?({:error, _}, :code.lib_dir(:cadence_server))

if config_env() != :test do
  state_dir =
    System.get_env("CAD_STATE_DIR") ||
      Path.join(System.user_home!(), ".local/state/cadence")

  config :cadence_daemon, Cadence.Daemon.Repo, database: Path.join(state_dir, "cadence.db")

  config :cadence_daemon,
    ignore:
      System.get_env(
        "CAD_IGNORE",
        "_build,deps,node_modules,.venv,venv,__pycache__,.elixir_ls,target"
      )
      |> String.split(",", trim: true)

  darwin? = match?({:unix, :darwin}, :os.type())

  watch_backend =
    case System.get_env("CAD_WATCH_BACKEND") do
      # `fs_inotify` is Linux-only and `fs_mac` is Darwin-only in `file_system`;
      # selecting the wrong one stops the watcher, so fall back quietly.
      "fs_poll" -> :fs_poll
      "fs_mac" -> if(darwin?, do: :fs_mac, else: :fs_inotify)
      "fs_inotify" -> if(darwin?, do: :fs_poll, else: :fs_inotify)
      nil -> if(darwin?, do: :fs_poll, else: :fs_inotify)
      _ -> if(darwin?, do: :fs_poll, else: :fs_inotify)
    end

  config :cadence_daemon,
    watch_debounce_ms: String.to_integer(System.get_env("CAD_WATCH_DEBOUNCE_MS", "2000")),
    watch_backend: watch_backend,
    local_user_id: System.get_env("CAD_LOCAL_USER_ID", "00000000-0000-0000-0000-000000000000"),
    git_author: %{
      name: System.get_env("CAD_GIT_AUTHOR_NAME", "cadence"),
      email: System.get_env("CAD_GIT_AUTHOR_EMAIL", "cadence@local")
    }

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
      String.to_integer(System.get_env("CAD_DIFF_MAX_LINES_PER_FILE", "400")),
    diff_max_bytes: String.to_integer(System.get_env("CAD_DIFF_MAX_BYTES", "262144"))

  config :cadence_daemon,
    server_url: System.get_env("CAD_SERVER_URL"),
    auth_token: System.get_env("CAD_AUTH_TOKEN"),
    sync_enabled: System.get_env("CAD_SYNC_ENABLED", "true") == "true",
    sync_channel_enabled: System.get_env("CAD_SYNC_CHANNEL_ENABLED", "true") == "true",
    sync_request_timeout_ms:
      String.to_integer(System.get_env("CAD_SYNC_REQUEST_TIMEOUT_MS", "5000")),
    sync_union_timeout_ms:
      String.to_integer(System.get_env("CAD_SYNC_UNION_TIMEOUT_MS", "180000")),
    sync_interval_ms: String.to_integer(System.get_env("CAD_SYNC_INTERVAL_MS", "30000")),
    sync_retry_backoff_ms:
      String.to_integer(System.get_env("CAD_SYNC_RETRY_BACKOFF_MS", "30000")),
    sync_max_attempts: String.to_integer(System.get_env("CAD_SYNC_MAX_ATTEMPTS", "10")),
    sync_push_limit: String.to_integer(System.get_env("CAD_SYNC_PUSH_LIMIT", "100")),
    sync_exists_limit: String.to_integer(System.get_env("CAD_SYNC_EXISTS_LIMIT", "5000"))

  config :cadence_daemon,
    docs_enabled: System.get_env("CAD_DOCS_ENABLED", "true") == "true",
    docs_timeout_ms: String.to_integer(System.get_env("CAD_DOCS_TIMEOUT_MS", "30000")),
    docs_rate_limit: String.to_integer(System.get_env("CAD_DOCS_RATE_LIMIT", "5")),
    docs_rate_scale: String.to_integer(System.get_env("CAD_DOCS_RATE_SCALE", "60000")),
    docs_retry_attempts: String.to_integer(System.get_env("CAD_DOCS_RETRY_ATTEMPTS", "3")),
    docs_retry_backoff_ms: String.to_integer(System.get_env("CAD_DOCS_RETRY_BACKOFF_MS", "5000")),
    docs_max_ops: String.to_integer(System.get_env("CAD_DOCS_MAX_OPS", "20")),
    docs_max_files: String.to_integer(System.get_env("CAD_DOCS_MAX_FILES", "200")),
    docs_max_file_bytes: String.to_integer(System.get_env("CAD_DOCS_MAX_FILE_BYTES", "262144")),
    docs_context_bytes: String.to_integer(System.get_env("CAD_DOCS_CONTEXT_BYTES", "65536")),
    docs_diff_max_bytes: String.to_integer(System.get_env("CAD_DOCS_DIFF_MAX_BYTES", "32768"))
end

# -- Server -----------------------------------------------------------------

if config_env() != :test and server_artifact? do
  listen_port = String.to_integer(System.get_env("CAD_HTTP_PORT", "4000"))

  database_url =
    case {config_env(), System.get_env("CAD_DATABASE_URL")} do
      {:prod, nil} -> System.fetch_env!("CAD_DATABASE_URL")
      {_, nil} -> "ecto://postgres:postgres@localhost:5432/cadence_dev"
      {_, url} -> url
    end

  secret_key_base =
    case {config_env(), System.get_env("CAD_SECRET_KEY_BASE")} do
      {:prod, nil} -> System.fetch_env!("CAD_SECRET_KEY_BASE")
      {_, nil} -> String.duplicate("cadence-dev-secret-", 4)
      {_, value} -> value
    end

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
    secret_key_base: secret_key_base,
    live_view: [signing_salt: System.get_env("CAD_LIVE_VIEW_SALT") || secret_key_base]

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
    sync_exists_limit: String.to_integer(System.get_env("CAD_SYNC_EXISTS_LIMIT", "5000")),
    dag_intro_ms: String.to_integer(System.get_env("CAD_DAG_INTRO_MS", "1200")),
    file_max_bytes: String.to_integer(System.get_env("CAD_FILE_MAX_BYTES", "524288")),
    file_max_lines: String.to_integer(System.get_env("CAD_FILE_MAX_LINES", "2000")),
    readme_max_bytes: String.to_integer(System.get_env("CAD_README_MAX_BYTES", "262144")),
    tree_max_entries: String.to_integer(System.get_env("CAD_TREE_MAX_ENTRIES", "1000")),
    proposal_max_files: String.to_integer(System.get_env("CAD_PROPOSAL_MAX_FILES", "200")),
    scan_max_files: String.to_integer(System.get_env("CAD_SCAN_MAX_FILES", "10000")),
    scan_max_bytes: String.to_integer(System.get_env("CAD_SCAN_MAX_BYTES", "16777216")),
    repack_enabled: System.get_env("CAD_REPACK_ENABLED", "true") == "true",
    repack_min_objects: String.to_integer(System.get_env("CAD_REPACK_MIN_OBJECTS", "1000")),
    repack_min_bytes: String.to_integer(System.get_env("CAD_REPACK_MIN_BYTES", "67108864")),
    repack_interval_ms: String.to_integer(System.get_env("CAD_REPACK_INTERVAL_MS", "21600000")),
    repack_timeout_ms: String.to_integer(System.get_env("CAD_REPACK_TIMEOUT_MS", "600000")),
    repack_max_pack_bytes:
      String.to_integer(System.get_env("CAD_REPACK_MAX_PACK_BYTES", "67108864")),
    meld_timeout_ms: String.to_integer(System.get_env("CAD_MELD_TIMEOUT_MS", "60000")),
    meld_rate_limit: String.to_integer(System.get_env("CAD_MELD_RATE_LIMIT", "5")),
    meld_rate_scale: String.to_integer(System.get_env("CAD_MELD_RATE_SCALE", "60000")),
    meld_max_ops: String.to_integer(System.get_env("CAD_MELD_MAX_OPS", "50")),
    meld_max_file_bytes: String.to_integer(System.get_env("CAD_MELD_MAX_FILE_BYTES", "262144")),
    meld_context_bytes: String.to_integer(System.get_env("CAD_MELD_CONTEXT_BYTES", "65536")),
    meld_retry_attempts: String.to_integer(System.get_env("CAD_MELD_RETRY_ATTEMPTS", "1")),
    meld_retry_backoff_ms: String.to_integer(System.get_env("CAD_MELD_RETRY_BACKOFF_MS", "500")),
    actions_enabled: System.get_env("CAD_ACTIONS_ENABLED", "true") == "true",
    docker_socket: System.get_env("CAD_DOCKER_SOCKET", "http://localhost:2375"),
    artifact_path: System.get_env("CAD_ARTIFACT_PATH", "/data/artifacts"),
    actions_max_manifest_bytes:
      String.to_integer(System.get_env("CAD_ACTIONS_MAX_MANIFEST_BYTES", "32768")),
    actions_max_actions: String.to_integer(System.get_env("CAD_ACTIONS_MAX_ACTIONS", "20")),
    actions_volume: System.get_env("CAD_ACTIONS_VOLUME", "cadence_actions"),
    actions_volume_path: System.get_env("CAD_ACTIONS_VOLUME_PATH", "/data/actions"),
    actions_timeout_ms: String.to_integer(System.get_env("CAD_ACTIONS_TIMEOUT_MS", "120000")),
    actions_max_concurrent_runs:
      String.to_integer(System.get_env("CAD_ACTIONS_MAX_CONCURRENT_RUNS", "1")),
    actions_max_queued_runs:
      String.to_integer(System.get_env("CAD_ACTIONS_MAX_QUEUED_RUNS", "20")),
    actions_dispatch_on_boot: System.get_env("CAD_ACTIONS_DISPATCH_ON_BOOT", "true") == "true",
    actions_artifact_retention_days:
      String.to_integer(System.get_env("CAD_ACTIONS_ARTIFACT_RETENTION_DAYS", "30")),
    actions_retention_interval_ms:
      String.to_integer(System.get_env("CAD_ACTIONS_RETENTION_INTERVAL_MS", "21600000")),
    actions_retention_batch:
      String.to_integer(System.get_env("CAD_ACTIONS_RETENTION_BATCH", "500")),
    actions_image_retention_per_project:
      String.to_integer(System.get_env("CAD_ACTIONS_IMAGE_RETENTION_PER_PROJECT", "5")),
    actions_build_timeout_ms:
      String.to_integer(System.get_env("CAD_ACTIONS_BUILD_TIMEOUT_MS", "300000")),
    actions_max_cpus: String.to_integer(System.get_env("CAD_ACTIONS_MAX_CPUS", "1")),
    actions_memory_mb: String.to_integer(System.get_env("CAD_ACTIONS_MEMORY_MB", "512")),
    actions_pids_limit: String.to_integer(System.get_env("CAD_ACTIONS_PIDS_LIMIT", "256")),
    actions_network: System.get_env("CAD_ACTIONS_NETWORK", "none"),
    actions_build_network: System.get_env("CAD_ACTIONS_BUILD_NETWORK", "none"),
    docker_api_version: System.get_env("CAD_DOCKER_API_VERSION", "v1.45"),
    actions_max_log_bytes:
      String.to_integer(System.get_env("CAD_ACTIONS_MAX_LOG_BYTES", "1048576")),
    actions_max_artifact_bytes:
      String.to_integer(System.get_env("CAD_ACTIONS_MAX_ARTIFACT_BYTES", "33554432")),
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

  # Demo auth is a build-time flag (see config/config.exs and
  # Cadence.Server.Accounts.User). A prod release must never carry it.
  if config_env() == :prod and System.get_env("CAD_DEMO_AUTH") == "true" do
    raise """
    CAD_DEMO_AUTH must never be set for a production boot.

    The demo password strategy is compiled in only when CAD_DEMO_AUTH=true at
    build time. Rebuild the prod artifact without the flag and unset it in the
    production environment.
    """
  end
end

config :cadence_shared, Cadence.Shared.LLM,
  provider: System.get_env("CAD_LLM_PROVIDER", "deepseek"),
  api_key: System.get_env("CAD_LLM_API_KEY"),
  model: System.get_env("CAD_LLM_MODEL", "deepseek-chat"),
  base_url: System.get_env("CAD_LLM_BASE_URL", "https://api.deepseek.com")
