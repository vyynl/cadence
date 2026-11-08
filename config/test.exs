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
  llm_retry_attempts: 3,
  sync_exists_limit: 5_000

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
  demo_auth: true,
  token_signing_secret: String.duplicate("test-token-signing-secret-", 4),
  public_url: "http://localhost:4000",
  git_store_path:
    Path.join(System.tmp_dir!(), "cadence_test_git_#{System.unique_integer([:positive])}"),
  artifact_path:
    Path.join(System.tmp_dir!(), "cadence_test_artifacts_#{System.unique_integer([:positive])}"),
  actions_volume: "cadence_test_actions",
  actions_volume_path:
    Path.join(System.tmp_dir!(), "cadence_test_actions_#{System.unique_integer([:positive])}"),
  actions_timeout_ms: 5_000,
  actions_build_timeout_ms: 10_000,
  # Keep the queue bound deterministic in tests; the boot dispatch would query
  # the sandboxed Repo from a process that does not own a connection.
  actions_max_concurrent_runs: 1,
  actions_dispatch_on_boot: false,
  # Retention is opt-in per test; the backstop must not sweep the shared
  # artifact temp dir while other tests are running.
  actions_artifact_retention_days: 30,
  actions_retention_interval_ms: 0,
  actions_retention_batch: 500,
  actions_image_retention_per_project: 5,
  actions_max_cpus: 1,
  actions_memory_mb: 512,
  actions_pids_limit: 256,
  actions_network: "none",
  actions_build_network: "none",
  docker_api_version: "v1.45",
  actions_max_log_bytes: 1_048_576,
  actions_max_artifact_bytes: 1_048_576,
  sync_pull_limit: 100,
  sync_exists_limit: 5_000,
  dag_intro_ms: 0,
  file_max_bytes: 4096,
  file_max_lines: 100,
  readme_max_bytes: 4096,
  tree_max_entries: 100,
  proposal_max_files: 200,
  scan_max_files: 1000,
  scan_max_bytes: 65_536,
  # Background repacking must never reach the database from a spawned task in
  # the sandbox: keep the threshold unreachable and the backstop off. The
  # repacker tests opt in with explicit values.
  repack_enabled: true,
  repack_min_objects: 1_000_000,
  repack_min_bytes: 1_073_741_824,
  repack_interval_ms: 0,
  repack_max_pack_bytes: 67_108_864,
  meld_timeout_ms: 5_000,
  meld_rate_limit: 100,
  meld_max_ops: 10,
  meld_max_file_bytes: 4_096,
  meld_context_bytes: 8_192,
  meld_retry_attempts: 1,
  meld_retry_backoff_ms: 0,
  oauth: []
