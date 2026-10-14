import Config

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
