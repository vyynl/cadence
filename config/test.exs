import Config

config :logger, level: :warning

config :cadence_daemon, Cadence.Daemon.Repo,
  database: ":memory:",
  pool_size: 1

config :cadence_daemon,
  watch_debounce_ms: 50,
  watch_backend: :fs_poll,
  local_user_id: "00000000-0000-0000-0000-000000000000",
  start_api: false,
  llm_retry_backoff_ms: 60_000,
  llm_retry_attempts: 3

config :cadence_server, Cadence.Server.Repo,
  url:
    System.get_env(
      "CAD_TEST_DATABASE_URL",
      "ecto://postgres:postgres@localhost:55432/cadence_test"
    ),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :cadence_server, Cadence.ServerWeb.Endpoint,
  server: false,
  secret_key_base: String.duplicate("test-secret-key-base-", 4),
  live_view: [signing_salt: "test-live-view-salt"]

config :cadence_server,
  token_signing_secret: String.duplicate("test-token-signing-secret-", 4),
  public_url: "http://localhost:4000",
  git_store_path:
    Path.join(System.tmp_dir!(), "cadence_test_git_#{System.unique_integer([:positive])}"),
  sync_pull_limit: 100,
  dag_intro_ms: 0,
  oauth: []
